#- NQPMixinCacheHOW ------------------------------------------------------------

knowhow NQPMixinCacheHOW {
    method new_type($class_type) {
        my $mo   := nqp::create(self);
        my $type := nqp::newtype($mo, 'Uninstantiable');
        nqp::setparameterizer($type, sub ($type, @roles) {
            $class_type.HOW.generate_mixin($class_type, @roles)
        });
        nqp::setdebugtypename(
          $type, $class_type.HOW.name($class_type) ~ ' mixin cache'
        );
        $type
    }
    method name($XXX?) { 'mixin cache' }
}

#- NQPClassHOW -----------------------------------------------------------------
# This is a first cut at a ClassHOW for NQP. It doesn't support all the stuff
# that Raku needs, but it's sufficient for NQP. Supports methods, attributes,
# role composition, inheritance (single and multiple) and introspection.
knowhow NQPClassHOW {

    # Name of the class.
    has $!name;

    # Attributes, methods, parents and roles directly added.
    has $!attributes;
    has $!methods;
    has $!method_order;
    has $!tweaks;
    has $!parents;
    has $!roles;
    has $!default_parent;

    # Array type support.
    has $!is_array_type;   # Bool
    has $!array_type;

    # Multi methods to add at compose time
    has $!multi_methods;

    # Have we been composed?
    has $!composed;        # Bool

    # Are we a class with mixins?
    has $!is_mixin;

    # Cached MRO (list of the type objects).
    has $!mro;

    # Full list of roles that we do.
    has $!done;

    # If needed, a cached flattened method table accounting for all methods in
    # this class and its parents. This is only needed in the situation that a
    # megamorphic callsite involves the class, so calculated and cached on
    # demand.
    has $!cached_all_method_table;

    # Cached values, which are thrown away if the class changes. We don't ever
    # mutate the $!caches hash, but instead clone/mutate/replace; additions
    # are rare compared to lookups, and this beats locking.
    has $!caches;

    has $!mixin_cache;

    # Build plans
    has $!BUILDALLPLAN;
    has $!BUILDPLAN;

    has $!lock;

    my $archetypes := Archetypes.new( :nominal, :inheritable );
    method archetypes($XXX?) { $archetypes }

    # Creates a new instance of this meta-class
    method new(:$name = '<anon>') {
        my $obj := nqp::create(self);
        nqp::bindattr($obj, NQPClassHOW, '$!name', $name);

        nqp::bindattr($obj, NQPClassHOW, '$!methods', nqp::hash);
        nqp::bindattr($obj, NQPClassHOW, '$!caches',  nqp::hash);

        nqp::bindattr($obj, NQPClassHOW, '$!attributes',    nqp::list);
        nqp::bindattr($obj, NQPClassHOW, '$!method_order',  nqp::list);
        nqp::bindattr($obj, NQPClassHOW, '$!tweaks',        nqp::list);
        nqp::bindattr($obj, NQPClassHOW, '$!multi_methods', nqp::list);
        nqp::bindattr($obj, NQPClassHOW, '$!parents',       nqp::list);
        nqp::bindattr($obj, NQPClassHOW, '$!roles',         nqp::list);
        nqp::bindattr($obj, NQPClassHOW, '$!mro',           nqp::list);
        nqp::bindattr($obj, NQPClassHOW, '$!done',          nqp::list);
        nqp::bindattr($obj, NQPClassHOW, '$!BUILDPLAN',     nqp::list);
        nqp::bindattr($obj, NQPClassHOW, '$!BUILDALLPLAN',  nqp::list);

        nqp::bindattr($obj, NQPClassHOW, '$!lock', NQPHOWLock.new);
        $obj
    }

    # Create a new meta-class instance, and then a new type object
    # to go with it, and return that.
    method new_type(
      :$name = '<anon>',
      :$repr = 'P6opaque',
      :$array_type,
      :$is_mixin
    ) {
        my $metaclass := self.new(:name($name));
        my $new_type := $metaclass.set_is_mixin($is_mixin)
          ?? nqp::newmixintype($metaclass, $repr)
          !! nqp::newtype($metaclass, $repr);
        $metaclass.setup_mixin_cache($new_type);
        nqp::settypehll($new_type, 'nqp');
        nqp::setdebugtypename(nqp::setwho($new_type, nqp::hash), $name)
    }

    method add_method($target, $name, $code) {
        nqp::die("Cannot add a null method '$name' to class '$!name'")
          if nqp::isnull($code) || !nqp::defined($code);

        nqp::die("This class already has a method named " ~ $name)
          if nqp::existskey($!methods, $name);

        $!lock.protect({

            $!methods      := bindkey_on_clone($!methods, $name, $code);
            $!method_order := push_on_clone($!method_order, $code);
            $!cached_all_method_table := nqp::null;
        });
    }

    method add_multi_method($target, $name, $code) {

        $!lock.protect({

            # We can't incorporate these right away as we don't know all
            # parents yet, maybe, which influences whether we even can
            # have multis, need to generate a proto or worry. So just
            # queue them up in a todo list and we handle it at class
            # composition time.
            $!multi_methods := push_on_clone($!multi_methods, [$name, $code]);
            $!cached_all_method_table := nqp::null;
        });

        $code
    }

    # Add an attribute with the given meta information
    method add_attribute($obj, $attribute) {

        # Make sure name is unique
        my $attributes := $!attributes;
        my $name := $attribute.name;
        my $m := nqp::elems($attributes);
        my $i := 0;
        while $i < $m {
            nqp::atpos($attributes, $i).name eq $name
              ?? nqp::die("This class already has an attribute named '$name'")
              !! ++$i;
        }

        $!lock.protect({
            # Note: use previously saved for consistency in update
            $!attributes := push_on_clone($attributes, $attribute);
        });

        $attribute
    }

    method is_array_type($XXX?) { $!is_array_type }
    method array_type(   $XXX?) { $!array_type    }
    method set_array_type($XXX, $type) {

        $!lock.protect({
            $!is_array_type := 1;
            $!array_type := $type;
        });
    }

    method add_parent($target, $parent) {
        nqp::die(
          "NQPClassHOW does not support adding parents after being composed."
        ) if $!composed;

        nqp::die("Class '$!name' cannot inherit from itself.")
          if nqp::eqaddr($target,$parent);

        my $parents := $!parents;
        my $m := nqp::elems($parents);
        my $i := 0;
        while $i < $m {
            nqp::eqaddr(nqp::atpos($parents, $i), $parent)
              ?? nqp::die("Already have " ~ $parent ~ " as a parent class.")
              !! ++$i;
        }

        $!lock.protect({
            # Note: use previously saved for consistency in update
            $!parents := push_on_clone($parents, $parent);
        });

        $parent
    }

    method set_default_parent($XXX, $parent) {
        $!default_parent := $parent  # doesn't need protecting
    }

    # Helper sub: returns 1 if none of the parents of a given mro have
    # attributes, else 0
    sub attributeless_parents($type) {
        my $mro := $type.HOW.mro($type);
        my $m   := nqp::elems($mro);
        my $i   := 0;

        while $i < $m {
            my $type := nqp::atpos($mro, $i);
            nqp::elems($type.HOW.attributes($type, :local))
              ?? (return 0)
              !! ++$i;
        }
        1
    }

    # Changes the object's parent. Conditions: it has exactly one parent,
    # and that parent has no attributes, and nor does the new one.
    method reparent($target, $new_parent) {
        my $parents := $!parents;

        nqp::die("Can only re-parent a class with exactly one parent")
          if nqp::elems($parents) != 1;

        nqp::die(
          "Can only re-parent a class whose parent has no attributes"
        ) unless attributeless_parents(nqp::atpos($parents, 0));

        nqp::die("Can only re-parent to a class with no attributes")
          unless attributeless_parents($new_parent);

        $!lock.protect({
            $parents := nqp::clone($!parents);
            nqp::bindpos($parents, 0, $new_parent);
            $!parents := $parents;
            $!mro := compute_c3_mro($target);
            $!cached_all_method_table := nqp::null;

            self.publish_type_cache($target);
            self.publish_boolification_spec($target);
        });

        1;
    }

    method add_role($XXX, $role) {
        my $roles := $!roles;
        my $m := nqp::elems($roles);
        my $i := 0;
        while $i < $m {
            nqp::eqaddr(nqp::atpos($roles, $i), $role)
              ?? nqp::die("The role " ~ $role ~ " has already been added.")
              !! ++$i;
        }

        $!lock.protect({
            $roles := $!roles;  # XXX nqp::clone breaks build
            nqp::push($!roles, $role);
            $!roles := $roles;
        });
    }


    # Incorporate roles
    method compose($target) {
        $!lock.protect({

            # If not done by another thread
            unless $!composed {

                # Local aliases for faster access
                my $roles  := $!roles;
                my $done   := $!done;

                # Set up tweaks, first the one of this class, if any
                my $tweaks := nqp::clone($!tweaks);
                if nqp::atkey($!methods, 'TWEAK') -> $tweak {
                    nqp::push($tweaks, $tweak);
                }

                # First, specialize them with the type object for this type (so
                # their $?CLASS is correct). Then delegate to the composer
                if nqp::elems($roles) -> $m {
                    my @specialized_roles;
                    my $i := 0;
                    while $i < $m {
                        my $role        := nqp::atpos($roles, $i);
                        my $specialized := $role.HOW.specialize($role, $target);

                        nqp::push(@specialized_roles, $specialized);
                        nqp::push($done, $role);
                        nqp::push($done, $specialized);

                        # Make sure we know of any additional tweaks
                        my $how := $specialized.HOW;
                        if nqp::tryfindmethod($how, 'tweaks') -> $method {
                            append($tweaks, $method($how, $specialized));
                        }

                        ++$i;
                    }

                    $!done := $done;  # update atomically
                    RoleToClassApplier.apply($target, @specialized_roles);
                }

                # Make sure the updated tweaks are known
                $!tweaks := $tweaks;

                # If we have no parents and we're not called NQPMu then add the
                # default parent
                $!parents := nqp::list($!default_parent)
                  if nqp::elems($!parents) == 0 && $!name ne 'NQPMu';

                # Compute the MRO
                $!mro := compute_c3_mro($target);

                # Incorporate any new multi candidates (needs MRO built)
                self.incorporate_multi_candidates($target);

                # Compose any attributes, local or not
                my $attributes := self.attributes($target, :!local);
                if nqp::elems($attributes) -> $m {
                    my $i := 0;
                    while $i < $m {
                        nqp::atpos($attributes, $i).compose($target);
                        ++$i;
                    }
                }

                # Publish type and method caches and boolification spec.
                self.publish_type_cache($target);
                self.publish_boolification_spec($target);

                # Create BUILDPLAN.
                self.create_BUILDPLAN($target);

                self.compose_repr($target);
                $!composed := 1;
            }
        });

        $target
    }

    # Compose the representation of the given object.  Assumes this is
    # called from insided a protected block
    method compose_repr($target) {

        # Handle arrays differently
        if self.is_array_type {
            nqp::elems(self.attributes($target))
              ?? nqp::die("Cannot have attributes on an array representation")
              !! nqp::composetype(
                   nqp::decont($target),
                   nqp::hash(
                     'array',
                     nqp::hash('type', nqp::decont(self.array_type))
                   )
                 );
        }

        # Handle anything else
        else {

            # Use any attribute information to produce attribute protocol
            # data. The protocol consists of an array...
            my @repr_info;

            my $mro := $!mro;
            my $m := nqp::elems($mro);
            my $i := 0;
            # ...which contains an array per MRO entry...
            while $i < $m {
                my $type_obj := nqp::atpos($mro, $i);
                my @type_info;

                # ...which in turn contains the current type in the MRO...
                nqp::push(@type_info, $type_obj);

                # ...then an array of hashes per attribute...
                my @attrs_info;
                my $attributes := $type_obj.HOW.attributes($type_obj, :local);
                my $n := nqp::elems($attributes);
                my $j := 0;
                while $j < $n {
                    my $attribute := nqp::atpos($attributes, $j);
                    my $info := nqp::hash(
                      'name', $attribute.name, 'type', $attribute.type
                    );

                    # Merely having the key serves as a "yes"
                    nqp::bindkey($info, 'box_target', 1)
                      if $attribute.box_target;

                    nqp::bindkey(
                      $info, 'auto_viv_container', $attribute.auto_viv_container
                    ) if nqp::can($attribute, 'auto_viv_container');

                    nqp::bindkey($info, 'positional_delegate', 1)
                      if $attribute.positional_delegate;

                    nqp::bindkey($info, 'associative_delegate', 1)
                      if $attribute.associative_delegate;

                    nqp::push(@attrs_info, $info);
                    ++$j;
                }
                nqp::push(@type_info, @attrs_info);

                # ...followed by a list of immediate parents.
                nqp::push(@type_info, $type_obj.HOW.parents($type_obj, :local));

                # and shove that into the protocol array
                nqp::push(@repr_info, @type_info);
                ++$i;
            }

            # Compose the representation using it
            nqp::composetype($target, nqp::hash('attribute', @repr_info));
        }
    }

    # Helper sub to find a dispatcher for the given MRO and method name
    sub find_dispatcher($mro, $name) {
        my $m := nqp::elems($mro);
        my $i := 1;  # skip ourselves
        while $i < $m {
            my $parent     := nqp::atpos($mro, $i);
            my $dispatcher := nqp::atkey($parent.HOW.method_table, $name);

            # Found a possible - make sure it's a dispatcher, not an only
            unless nqp::isnull($dispatcher) {
                nqp::can($dispatcher, 'is_dispatcher')
                  && $dispatcher.is_dispatcher
                  ?? (return $dispatcher)
                  !! nqp::die("Could not find a proto for multi $name (it may exist, but an only is hiding it if so)");
            }
            ++$i;
        }
        nqp::die(
          "Could not find a proto for multi $name, and proto generation is NYI"
        )
    }

    # Incorporate any multi methods into the methods hash.  Assumes it is
    # being called from a protected block
    method incorporate_multi_candidates($XXX?) {
        my $mro           := $!mro;
        my $multi_methods := $!multi_methods;
        my $methods       := nqp::clone($!methods);  # being updated

        my $m := nqp::elems($multi_methods);
        my $i := 0;
        while $i < $m {
            # Get method name and code.
            my $entry := nqp::atpos($multi_methods, $i);
            my $name  := nqp::atpos($entry, 0);
            my $code  := nqp::atpos($entry, 1);

            # Do we have anything in the methods table already in
            # this class?
            my $dispatcher := nqp::atkey($methods, $name);

            if nqp::defined($dispatcher) {

                # Yes. Only or dispatcher, though? If only, error. If
                # dispatcher, simply add new dispatchee.
                nqp::can($dispatcher, 'is_dispatcher')
                  && $dispatcher.is_dispatcher
                  ?? $dispatcher.add_dispatchee($code)
                  !! nqp::die("Cannot have a multi candidate for $name when an only method is also in the class");
            }

            # No dispatcher found yet, find one
            else {
                my $dispatcher := find_dispatcher($mro, $name);
                my $derived    := $dispatcher.derive_dispatcher;
                $derived.add_dispatchee($code);
                nqp::bindkey($methods, $name, $derived);
            }
            ++$i;
        }

        $!methods := $methods;
    }

    # Helper sub to compute the C3 MRO for a given class
    sub compute_c3_mro($class) {
        my @result;
        my @parents := $class.HOW.parents($class, :local);
        my $elems   := nqp::elems(@parents);

        # Only one immediate parent
        if $elems == 1 {
            @result := compute_c3_mro(nqp::atpos(@parents,0));
        }

        # More than one immediate parent
        elsif $elems {

            # Build merge list of linearizations of all our parents,
            # add immediate parents and merge
            my @merge_list;
            my $i := 0;
            while $i < $elems {
                nqp::push(
                  @merge_list,
                  compute_c3_mro(nqp::atpos(@parents,$i))
                );
                ++$i;
            }
            nqp::push(@merge_list, @parents);
            @result := c3_merge(@merge_list);
        }

        # Put this class on the start of the list, and we're done
        nqp::unshift(@result, $class);
        @result
    }

    # Helper sub to perform C3 merges
    sub c3_merge(@merge_list) {
        my @result;
        my $accepted;
        my $something_accepted;
        my $cand_count := 0;

        # Try to find something appropriate to add to the MRO.
        my $elems := nqp::elems(@merge_list);
        my $i     := 0;
        while $i < $elems {
            my @candidates := nqp::atpos(@merge_list, $i);
            if nqp::elems(@candidates) {

                my $rejected;
                my $cand_class := nqp::atpos(@candidates,0);
                ++$cand_count;

                # Go check the merge list again
                my $j := 0;
                while $j < $elems {

                    # Skip current list.
                    unless $j == $i {
                        my @check := nqp::atpos(@merge_list, $j);

                        # Is current candidate in the tail? If so, reject.
                        my $cur_pos := 1;
                        while $cur_pos < nqp::elems(@check) {
                            $rejected := 1
                              if nqp::eqaddr(
                                   nqp::atpos(@check, $cur_pos),
                                   $cand_class
                                 );
                            ++$cur_pos;
                        }
                    }
                    ++$j;
                }

                # If we didn't reject it, this candidate will do.
                unless $rejected {
                    $accepted := $cand_class;
                    $something_accepted := 1;
                    last;
                }
            }
            ++$i;
        }

        # If we never found any candidates, return an empty list.
        return @result if $cand_count == 0;

        # If we didn't find anything to accept, error.
        nqp::die("Could not build C3 linearization: ambiguous hierarchy")
          unless $something_accepted;

        # Otherwise, remove what was accepted from the merge lists
        $i := 0;
        while $i < $elems {
            my @new;
            my @old := nqp::atpos(@merge_list, $i);
            my $n := nqp::elems(@old);
            my $j := 0;
            while $j < $n {
                my $candidate := nqp::atpos(@old, $j);
                nqp::push(@new, $candidate)
                  unless nqp::eqaddr($candidate, $accepted);
                ++$j;
            }
            nqp::bindpos(@merge_list, $i, @new);
            ++$i;
        }

        # Need to merge what remains of the list, then put what was accepted on
        # the start of the list, and we're done.
        @result := c3_merge(@merge_list);
        nqp::unshift(@result, $accepted);
        @result
    }

    # Create and publish the type cache.  Assumes being run inside a
    # protected block
    method publish_type_cache($target) {
        my $mro := $!mro;

        # Make sure we only add unique types
        my $seen := nqp::hash;

        # Helper sub to recursively add new types and their roles
        my @tc;
        sub add_roles($type) {
            my $key := ~nqp::objectid($type);
            unless nqp::existskey($seen, $key) {
                nqp::bindkey($seen, $key, 1);

                nqp::push(@tc, $type);
                if nqp::can($type.HOW, 'role_typecheck_list') {
                    my @roles := $type.HOW.role_typecheck_list($type);
                    if nqp::elems(@roles) -> $m {
                        my $i := 0;
                        while $i < $m {
                            add_roles(nqp::atpos(@roles, $i));
                            ++$i;
                        }
                    }
                }
            }
        }

        my $m := nqp::elems($mro);
        my $i := 0;
        while $i < $m {
            add_roles(nqp::atpos($mro, $i));
            ++$i;
        }

        nqp::settypecache($target, @tc)
    }


    # Return a hash with the methodes keyed on name.  Updates the table if
    # it wasn't set yet in a thread-safe way
    method all_method_table($XXX?) {
        my $table := $!cached_all_method_table;
        unless nqp::isconcrete($table) {
            my $mro := $!mro;

            $table := nqp::hash;
            my $i := nqp::elems($mro);
            while --$i >= 0 {  # lower methods shadow methods higher up
                my $type := nqp::atpos($mro, $i);
                for $type.HOW.method_table {
                    nqp::bindkey($table, nqp::iterkey_s($_), nqp::iterval($_));
                }
            }
            nqp::scwbdisable;
            $!cached_all_method_table := $table;
            nqp::scwbenable;
        }
        $table
    }

    # Publish the way the object is supposed to be boolified
    method publish_boolification_spec($target) {
        my $bool_meth := self.find_method($target, 'Bool');
        nqp::defined($bool_meth)
          ?? nqp::setboolspec($target, 0, $bool_meth)
          !! nqp::setboolspec($target, 5, nqp::null);
    }

    # Creates the plan for building up the object. This works
    # out what we'll need to do up front, so we can just zip
    # through the "todo list" each time we need to make an object.
    # The plan is an array of tasks. A task is either a method to
    # be called, or an array in which The first element is an "op"
    # representing the task to perform:
    #   code = call specified BUILD method
    #   0 class name attr_name = find initialization value
    #   400 class attr_name code = call default value closure if uninitialized
    #   1100 class name attr_name = find initialization value, or set []
    #   1200 class name attr_name = find initialization value, or set {}
    # Note the numbers are a bit odd, but they are this way to conform to the
    # HLL version of BUILDALL.  Assumes it is being called from a protected
    # block.
    method create_BUILDPLAN($target) {

        # First, we'll create the build plan for just this class.
        my @plan;
        my @attributes := $target.HOW.attributes($target, :local);
        my $m := nqp::elems(@attributes);
        my $i := 0;

        # Does it have its own BUILD?
        my $methods := $target.HOW.method_table;
        my $build   := nqp::atkey($methods, 'BUILD');

        # No custom BUILD
        if nqp::isnull($build) {

            # Rather than having an actual BUILD in Mu, we produce ops
            # here per attribute that may need initializing.

            while $i < $m {
                my $name  := nqp::atpos(@attributes, $i).name;
                my $sigil := nqp::substr($name, 0, 1);
                nqp::push(@plan, [
                  $sigil eq '@' ?? 1100 !! $sigil eq '%' ?? 1200 !! 0,
                  $target, $name, nqp::substr($name, 2)
                ]);
                ++$i;
            }
            $i := 0;  # reset for attributes loop
        }

        # A custom BUILD
        else {
            nqp::push(@plan, $build);
        }

        # Check if there's any default values to put in place.
        while $i < $m {
            my $attribute := nqp::atpos(@attributes, $i);
            if nqp::can($attribute, 'build') {
                my $default := $attribute.build;
                nqp::push(@plan, [400, $target, $attribute.name, $default])
                  if nqp::defined($default);
            }
            ++$i;
        }

        # Make sure all the tweaks are run
        append(@plan, $!tweaks);

        # Install plan for this class.
        $!BUILDPLAN := @plan;

        # Now create the full plan by getting the MRO, and working from
        # least derived to most derived, copying the plans.
        my @all_plan;
        my $mro := $!mro;
        $i := nqp::elems($mro);
        while --$i >= 0 {
            my $class := nqp::atpos($mro, $i);
            append(@all_plan, $class.HOW.BUILDPLAN($class));
        }
        $!BUILDALLPLAN := @all_plan;
    }

    method parents($XXX?, :$local = 0) {
        $local ?? $!parents !! $!mro
    }

    method roles($XXX?, :$local!) {
        $!roles
    }

    method name($XXX?)                { $!name         }
    method BUILDPLAN($XXX?)           { $!BUILDPLAN    }
    method BUILDALLPLAN($XXX?)        { $!BUILDALLPLAN }
    method mro($XXX?)                 { $!mro          }
    method role_typecheck_list($XXX?) { $!done         }
    method method_table($XXX?)        { $!methods      }
    method tweaks($XXX?)              { $!tweaks       }

    method declares_method($XXX, $name) {
        nqp::existskey($!methods, $name)
    }
    method code_of_method($XXX, $name) {
        nqp::atkey($!methods, $name)
    }

    method methods($XXX?, :$local = 0, :$all) {
        if $local {
            nqp::clone($!method_order)
        }
        else {
            my $mro := $!mro;
            my @methods;
            my $m := nqp::elems($mro);
            my $i := 0;
            while $i < $m {
                my $class := nqp::atpos($mro, $i);
                append(@methods, $class.HOW.methods($class, :local));
                ++$i;
            }
            @methods
        }
    }

    method submethod_table($XXX?) { nqp::hash }

    method shortname($target) { shortened_name($target) }

    method attributes($XXX?, :$local = 0) {
        if $local {
            nqp::clone($!attributes)
        }
        else {
            my @attributes;

            my $mro := $!mro;
            my $m := nqp::elems($mro);
            my $i := 0;
            while $i < $m {
                my $type := nqp::atpos($mro, $i);
                append(@attributes, $type.HOW.attributes($type, :local));
                ++$i;
            }
            @attributes
        }
    }

    method isa($XXX, $check) {
        my $check-class := $check.WHAT;
        my $mro := $!mro;

        my $i := nqp::elems($mro);
        while --$i >= 0 {
            return 1
              if nqp::eqaddr(nqp::atpos($mro,$i), $check-class);
        }
        0
    }

    method does($XXX, $check) {
        my $done := $!done;
        my $i := nqp::elems($done);
        while --$i >= 0 {
            return 1
              if nqp::eqaddr(nqp::atpos($done,$i), $check);
        }
        0
    }

    method can($target, $name) {
        my $mro := $!mro;

        my $m := nqp::elems($mro);
        my $i := 0;
        while $i < $m {
            my $can := nqp::atkey(
              nqp::atpos($mro, $i).HOW.method_table, $name
            );
            nqp::defined($can)
              ?? (return $can)
              !! ++$i;
        }
        0
    }

    method find_method($target, $name, :$no_fallback = 0) {
        my $mro := $!mro;
        my $m := nqp::elems($mro);
        my $i := 0;
        while $i < $m {
            my $method := nqp::atkey(
              nqp::atpos($mro, $i).HOW.method_table,$name
            );
            nqp::isconcrete($method)
              ?? (return $method)
              !! ++$i;
        }
        nqp::null
    }

    method cache($XXX, $key, $value_generator) {
        my $value := nqp::atkey($!caches, $key);

        # Not in cache
        if nqp::isnull($value) {
            $!lock.protect({
                nqp::bindkey(
                  (my $caches := nqp::clone($!caches)),
                  $key,
                  $value := $value_generator()
                );

                nqp::scwbdisable;
                $!caches := $caches;
                nqp::scwbenable;
            });
        }

        $value
    }

    method flush_cache($XXX?) {
        nqp::scwbdisable;
        $!caches := nqp::hash;
        nqp::scwbenable;
    }

    method cache_get($XXX, $key) { nqp::atkey($!caches, $key) }

    method cache_add($XXX, $key, $value) {
        $!lock.protect({
            my $caches  := nqp::clone($!caches);
            nqp::bindkey($caches, $key, $value);

            nqp::scwbdisable;
            $!caches := $caches;
            nqp::scwbenable;
        });

        $value
    }

    method is_mixin()              { $!is_mixin              }
    method set_is_mixin($is_mixin) { $!is_mixin := $is_mixin }
    method setup_mixin_cache($target) {
        $!mixin_cache := NQPMixinCacheHOW.new_type($target.WHAT);
    }

    method mixin($target, $role) {
        my @roles;
        nqp::push(@roles, $role);

        my $mixin_type := nqp::parameterizetype($!mixin_cache, @roles);

        # If the original object was concrete, change its type by calling a
        # low level op. Otherwise, we just return the new type object
        nqp::isconcrete($target)
          ?? nqp::rebless($target, $mixin_type)
          !! $mixin_type
    }

    method generate_mixin($target, @roles) {
        my $role := nqp::atpos(@roles, 0);
        # Flush its cache as promised, otherwise outdated NFAs will stick
        # around
        self.flush_cache($target) if !nqp::isnull($target) || self.is_mixin;

        # Work out a type name for the post-mixed-in role.
        my $name := self.name($target) ~ '+{' ~ $role.HOW.name($role) ~ '}';

        # Create new type, derive it from ourself and then add
        # all the roles we're mixing it.
        my $new_type := self.new_type(:$name, :repr($target.REPR), :is_mixin);
        $new_type.HOW.add_parent($new_type, $target.WHAT);
        $new_type.HOW.add_role($new_type, $role);

        $new_type.HOW.compose($new_type)
    }
}

nqp::bindcurhllsym('NQPClassHOW', NQPClassHOW);
