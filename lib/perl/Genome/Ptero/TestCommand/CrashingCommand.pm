package CrashingCommand;

use strict;
use warnings;

use UR;

class CrashingCommand {
    is => "Command::V2",
    has_input => [
        crashing_stage => {
            is => 'Text',
            valid_values => ['shortcut', 'execute'],
        },
    ],
    has_output => [
        out => {
        },
    ],
};

sub shortcut {
    my $self = shift;

    if ($self->crashing_stage eq 'shortcut') {
        die "TEST CRASHED AS EXPECTED IN SHORTCUT!";
    } else {
        return;
    }
};


sub execute {
    my $self = shift;

    if ($self->crashing_stage eq 'execute') {
        die "TEST CRASHED AS EXPECTED IN EXECUTE!";
    }
}

1;
