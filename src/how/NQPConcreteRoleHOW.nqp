#- NQPConcreteRoleHOW ----------------------------------------------------------
# This implements a concrete, parameterized instance of a role that
# can be composed into a class or mixed into an object.
knowhow NQPConcreteRoleHOW {

    # Name of the concrete role.
    has $!name;

    # What parametric role it was instantiated from.
    has $!instance_of;

    # Attributes and methods.
    has $!attributes;
    has $!methods;
    has $!method_order;
    has $!tweaks;
    has $!method_names;
    has $!multi_methods;
    has $!tweaks;
    has $!collisions;

    # Other roles that this one does.
    has $!roles;

    # All composed in roles.
    has $!role_typecheck_list;

    # Have we been composed?
    has $!composed;

    has $!lock;

    my $archetypes := Archetypes.new( :nominal, :composable );
    method archetypes($XXX?) { $archetypes }

    # Creates a new instance of this meta-class.
    method new(:$name!, :$instance_of!) {
        my $obj  := nqp::create(self);
        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!name',        $name       );
        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!instance_of', $instance_of);

        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!methods', nqp::hash);

        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!attributes',
          nqp::list);
        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!method_order',
          nqp::list);
        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!tweaks',
          nqp::list);
        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!method_names',
          nqp::list);
        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!multi_methods',
          nqp::list);
        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!collisions',
          nqp::list);
        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!roles',
          nqp::list);
        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!role_typecheck_list',
          nqp::list);

        nqp::bindattr($obj, NQPConcreteRoleHOW, '$!lock', NQPHOWLock.new);
        $obj
    }

    # Create a new meta-object instance, and then a new type object
    # to go with it, and return that
    method new_type(:$name = '<anon>', :$instance_of!) {
        my $metarole := self.new(:$name, :$instance_of);
        nqp::settypehll($metarole, 'nqp');
        nqp::setdebugtypename(nqp::newtype($metarole, 'Uninstantiable'), $name);
    }

    # Add a method in a threadsafe manner
    method add_method($XXX, $name, $code) {
        nqp::die("Cannot add a null method '$name' to role '$!name'")
          if nqp::isnull($code) || !nqp::defined($code);

        nqp::die("This role already has a method named " ~ $name)
          if nqp::existskey($!methods, $name);

        $!lock.protect({
            $!methods      := bindkey_on_clone($!methods, $name, $code);
            $!method_order := push_on_clone($!method_order, $code);
            $!method_names := push_on_clone($!method_names, $name);
        });
    }

    # Add a multi method in a threadsafe manner
    method add_multi_method($XXX, $name, $code) {
        # Queue them up for composition time
        $!lock.protect({
            $!multi_methods := push_on_clone($!multi_methods, [$name, $code]);
        });

        $code
    }

    # Add an attribute with the given meta information in a threadsafe manner
    method add_attribute($XXX, $attribute) {

        # Make sure name is unique
        my $attributes := $!attributes;
        my $name := $attribute.name;
        my $m := nqp::elems($attributes);
        my $i := 0;
        while $i < $m {
            nqp::atpos($attributes, $i).name eq $name
              ?? nqp::die("This role already has an attribute named " ~ $name)
              !! ++$i;
        }

        $!lock.protect({
            $!attributes := push_on_clone($!attributes, $attribute);
        });

        $attribute
    }

    method add_parent($XXX, $parent) {
        nqp::die("A role cannot inherit from a class in NQP")
    }

    # Add a role in a threadsafe manner
    method add_role($XXX, $role) {
        $!lock.protect({
            $!roles := push_on_clone($!roles, $role);
        });
    }

    # Add a name collision in a threadsafe manner
    method add_collision($XXX, $name) {
        if $name ne 'TWEAK' {
            $!lock.protect({
                $!collisions := push_on_clone($!collisions, $name);
            });
        }
    }

    # Compose the role. Beyond this point, no changes are allowed
    method compose($target) {
        # Incorporate roles. They're already instantiated. We need to
        # add to done list their instantiation source.
        $!lock.protect({

            # If not done by another thread
            unless $!composed {

                # Local aliases for faster access
                my $roles  := $!roles;

                # Set up tweaks, first the one of this role, if any
                my $tweaks := nqp::clone($!tweaks);
                if nqp::atkey($!methods, 'TWEAK') -> $tweak {
                    nqp::push($tweaks, $tweak);
                }

                if nqp::elems($roles) -> $m {
                    my $typecheck_list := nqp::clone($!role_typecheck_list);
                    my $i := 0;
                    while $i < $m {
                        my $role := nqp::atpos($roles, $i);
                        nqp::push($typecheck_list,$role);
                        nqp::push($typecheck_list,$role.HOW.instance_of($role));

                        # Make sure we know of any additional tweaks
                        append($tweaks, $role.HOW.tweaks($role));

                        ++$i;
                    }
                    $!role_typecheck_list := $typecheck_list;
                    RoleToRoleApplier.apply($target, $roles);
                }

                # Make sure the updated tweaks are known
                $!tweaks := $tweaks;

                # Mark composed.
                nqp::settypecache($target, [$target.WHAT]);
                $!composed := 1;
            }
        });

        $target
    }

    # Simple accessors
    method method_order($XXX?)        { $!method_order        }
    method method_names($XXX?)        { $!method_names        }
    method method_table($XXX?)        { $!methods             }
    method tweaks($XXX?)              { $!tweaks              }
    method collisions($XXX?)          { $!collisions          }
    method name($XXX?)                { $!name                }
    method role_typecheck_list($XXX?) { $!role_typecheck_list }
    method instance_of($XXX?)         { $!instance_of         }

    method declares_method($XXX, $name) {
        nqp::existskey($!methods, $name)
    }
    method code_of_method($XXX, $name) {
        nqp::atkey($!methods, $name)
    }

    # Other introspection
    method methods($XXX?, :$local, :$all) {
        $!method_order
    }
    method roles($XXX?, :$transitive = 0) {
        $!roles
    }
    method attributes($XXX?, :$local) {
        $!attributes
    }
    method shortname($target) { shortened_name($target) }
}
