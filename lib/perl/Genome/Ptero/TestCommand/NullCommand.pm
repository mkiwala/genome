package NullCommand;

use File::Path qw(make_path);
use File::Basename qw(dirname);
use UR;

class NullCommand {
    is => "Command::V2",
    has_input => [
        res1 => {
            is => "Text",
            is_optional => 1,
        },
        res2 => {
            is => "Text",
            is_optional => 1,
        },
        catcher => {
            is => "Text",
            is_optional => 1,
        },
        param => {
            is => "Text",
            doc => "A number",
            default_value => "x",
        },
    ],
    has_output => [
        animal => {
            is => "Text",
        },
    ],
    has => [
        lsf_resource => {
            default_value => "-M 200000 -n 4 -c 10 -R 'rusage[mem=200:gtmp=5]' -q short",
        },
    ]
};

sub execute {
    my $self = shift;
    print "param: " . $self->param . "\n";
    print "catcher: " . $self->catcher . "\n";
    $self->animal("frog");
    return 1;
}

1;
