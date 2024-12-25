#- NQPMu -----------------------------------------------------------------------
my class NQPMu {
    method CREATE() { nqp::create(self) }

    method new(*%attributes) {
        # Assume nobody will be overriding bless in NQP
        nqp::create(self).BUILDALL(%attributes)
    }
    method bless(NQPMu:U $self: *%attributes) {
        nqp::create(self).BUILDALL(%attributes)
    }

    method BUILDALL(NQPMu:D $self: %attrinit) {
        # Get the build plan.
        my $build_plan := self.HOW.BUILDALLPLAN(self);
        my int $count  := nqp::elems($build_plan);
        if $count {
        my int $i;
        while $i < $count {
            my $task := nqp::atpos($build_plan, $i);

            # Something with data
            if nqp::islist($task) {
                my int $code := nqp::atpos($task, 0);

                if nqp::iseq_i($code, 0) {
                    # See if we have a value to initialize this attr with.
                    my $key_name := nqp::atpos($task, 3);
                    if nqp::existskey(%attrinit, $key_name) {
                        nqp::bindattr(self, nqp::atpos($task, 1), nqp::atpos($task, 2), %attrinit{$key_name});
                    }
                }
                elsif nqp::iseq_i($code, 400) {
                    unless nqp::attrinited(self, nqp::atpos($task, 1), nqp::atpos($task, 2)) {
                        nqp::bindattr(self, nqp::atpos($task, 1), nqp::atpos($task, 2),
                            nqp::atpos($task, 3)(self,
                                nqp::getattr(self, nqp::atpos($task, 1), nqp::atpos($task, 2))));
                    }
                }
                elsif nqp::iseq_i($code, 1000) {
                    # Defeat lazy allocation
                    nqp::getattr(self, nqp::atpos($task, 1), nqp::atpos($task, 2))
                }
                elsif nqp::iseq_i($code, 1100) {
                    # See if we have a value to initialize this attr with;
                    # if not, set it to an empty array.
                    my $key_name := nqp::atpos($task, 3);
                    if nqp::existskey(%attrinit, $key_name) {
                        nqp::bindattr(self, nqp::atpos($task, 1), nqp::atpos($task, 2), %attrinit{$key_name});
                    }
                    else {
                        nqp::bindattr(self, nqp::atpos($task, 1), nqp::atpos($task, 2), nqp::list());
                    }
                }
                elsif nqp::iseq_i($code, 1200) {
                    # See if we have a value to initialize this attr with;
                    # if not, set it to an empty array.
                    my $key_name := nqp::atpos($task, 3);
                    if nqp::existskey(%attrinit, $key_name) {
                        nqp::bindattr(self, nqp::atpos($task, 1), nqp::atpos($task, 2), %attrinit{$key_name});
                    }
                    else {
                        nqp::bindattr(self, nqp::atpos($task, 1), nqp::atpos($task, 2), nqp::hash());
                    }
                }
                else {
                    nqp::die("Invalid BUILDALLPLAN");
                }
            }

            # Custom BUILD / TWEAK call
            else {
                $task(self, |%attrinit);
            }
            ++$i;
        }
        }
        self
    }

    method defined() { nqp::isconcrete(self) }

    proto method ACCEPTS($topic) {*}
    multi method ACCEPTS(NQPMu:U $self: $topic) {
        nqp::istype($topic, self.WHAT)
    }

    proto method NOT-ACCEPTS($topic) {*}
    multi method NOT-ACCEPTS(NQPMu:U $self: $topic) {
        nqp::isfalse(nqp::istype($topic, self.WHAT))
    }

    method isa($type) { self.HOW.isa(self, $type) }
}

# An NQP array, which is the standard array representation with a few methods
# added.
my class NQPArray is repr('VMArray') {
    method push($value)    { nqp::push(self, $value)    }
    method pop()           { nqp::pop(self)             }
    method unshift($value) { nqp::unshift(self, $value) }
    method shift()         { nqp::shift(self)           }
}
nqp::setboolspec(NQPArray, 8, nqp::null());
nqp::settypehllrole(NQPArray, nqp::const::HLL_ROLE_ARRAY);

# Iterator types.
my class NQPArrayIter is repr('VMIter') { }
nqp::setboolspec(NQPArrayIter, 7, nqp::null());

my class NQPHashIter is repr('VMIter') {
    method key()   { nqp::iterkey_s(self) }
    method value() { nqp::iterval(self)   }
    method Str()   { nqp::iterkey_s(self) }
}
nqp::setboolspec(NQPHashIter, 7, nqp::null());

# NQP HLL configuration.
nqp::sethllconfig('nqp', nqp::hash(
    'list',         NQPArray,
    'slurpy_array', NQPArray,
    'array_iter',   NQPArrayIter,
    'hash_iter',    NQPHashIter,
    'foreign_transform_hash', -> $hash {
        # BOOTHashes don't actually need transformation
        nqp::ishash($hash) ?? $hash !! $hash.FLATTENABLE_HASH
    },

    'call_dispatcher',        'nqp-call',
    'method_call_dispatcher', 'nqp-meth-call',
    'find_method_dispatcher', 'nqp-find-meth',
    'hllize_dispatcher',      'nqp-hllize',
    'istype_dispatcher',      'nqp-istype',
    'isinvokable_dispatcher', 'nqp-isinvokable',

));


nqp::register('nqp-hllize', -> $capture {
    nqp::guard('type', nqp::track('arg', $capture, 0));
    my $obj := nqp::captureposarg($capture, 0);

    if nqp::gettypehllrole($obj) == nqp::const::HLL_ROLE_HASH
      && !nqp::ishash($obj) {
        my $transform-hash :=
          nqp::how_nd($obj).find_method($obj, 'FLATTENABLE_HASH');
        nqp::die('Could not find method FLATTENABLE_HASH on '
          ~ nqp::how_nd($obj).name($obj)
          ~ ' object when trying to hllize'
        ) unless nqp::defined($transform-hash);

        nqp::delegate('lang-call',
          nqp::syscall(
            'dispatcher-insert-arg-literal-obj', $capture, 0, $transform-hash
          )
        );
    }
    else {
        nqp::delegate('boot-value', $capture);
    }
});


my class NQPLabel { }
