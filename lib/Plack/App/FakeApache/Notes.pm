package Plack::App::FakeApache::Notes;

use Moose;

has env => (
    is       => 'ro',
    isa      => 'HashRef[Any]',
    required => 1,
);

has ns => (
    is      => 'ro',
    isa     => 'Str',
    default => 'notes',
);

sub set {
    my ($self, $key, $value) = @_;
    $self->env()->{$self->ns().$key} = $value;
    return;
}


sub get {
    my ($self, $key) = @_;
    return $self->env()->{$self->ns().$key};
}

1;
