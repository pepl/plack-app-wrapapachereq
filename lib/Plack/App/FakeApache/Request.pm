package Plack::App::FakeApache::Request;

use Moose;

use APR::Pool;
use APR::Table;

use Plack::Request;
use Plack::Response;
use Plack::App::File;

use Plack::App::FakeApache::Connection;
use Plack::App::FakeApache::Log;
use Plack::App::FakeApache::Notes;
use Plack::App::FakeApache::Server;
use Cwd qw(cwd);
use URI;

use Apache2::Const qw(OK DONE);

my $NS = "plack.app.fakeapache";

# Plack related attributes:
has env => (
    is       => 'ro',
    isa      => 'HashRef[Any]',
    required => 1,
);

has plack_request => (
    is         => 'ro',
    isa        => 'Plack::Request',
    lazy_build => 1,
    handles    => {
        method       => 'method',
        unparsed_uri => 'request_uri',
        user         => 'user',
    },
);

has plack_response => (
    is         => 'ro',
    isa        => 'Plack::Response',
    lazy_build => 1,
    handles    => {
        set_content_length => 'content_length',
        content_type     => 'content_type',
        content_encoding => 'content_encoding',
        status           => 'status',
    },
);

has log => (
    is      => 'rw',
    default => sub { Plack::App::FakeApache::Log->new() },
    handles => [ qw(log_error log_reason warn) ],
);

has server => (
    is      => 'rw',
    default => sub { Plack::App::FakeApache::Server->new() },
);

has handler_status => (
    is         => 'rw',
    isa        => 'Int|Undef',
);

# Apache related attributes
has _apr_pool => (
    is         => 'ro',
    isa        => 'APR::Pool',
    lazy_build => 1,
);

has headers_in => (
    is         => 'ro',
    isa        => 'APR::Table',
    lazy_build => 1,
);

has headers_out => (
    is         => 'ro',
    isa        => 'APR::Table',
    lazy_build => 1,
);

has err_headers_out => (
    is         => 'ro',
    isa        => 'APR::Table',
    lazy_build => 1,
);

has _subprocess_env => (
    is         => 'ro',
    isa        => 'APR::Table',
    lazy_build => 1,
);

has _dir_config => (
    is         => 'ro',
    isa        => 'APR::Table',
    lazy_build => 1,
);

has location => (
    is      => 'rw',
    isa     => "Str",
    default => '/',
);

has filename => (
    is         => 'rw',
    isa        => 'Str|Undef',
    lazy_build => 1,
);

has root => (
    is         => 'rw',
    isa        => 'Str',
    default    => cwd(),
);

has is_initial_req => (
    is         => 'ro',
    isa        => 'Bool',
    default    => 1,
);

has auth_type => (
    is         => 'ro',
    isa        => 'Str',
);

has auth_name => (
    is         => 'ro',
    isa        => 'Str',
);

has protocol => (
    is      => 'ro',
    isa     => 'Str',
    default => 'HTTP/1.1',
);

# builders
sub _build_plack_request  { return Plack::Request->new( shift->env ) }
sub _build_plack_response { return Plack::Response->new( 200, {}, [] ) }
sub _build__apr_pool      { return APR::Pool->new() }
sub _build_headers_out    { return APR::Table::make( shift->_apr_pool, 64 ) }
sub _build_err_headers_out{ return APR::Table::make( shift->_apr_pool, 64 ) }
sub _build__dir_config    { return APR::Table::make( shift->_apr_pool, 64 ) }

sub _build__subprocess_env { 
    my $self  = shift;
    my $env   = $self->env;
    my $table = APR::Table::make( $self->_apr_pool, 64 );

    $table->add( $_ => $env->{$_} ) for grep { /^[_A-Z]+$/ } keys %$env;

    return $table;
}

sub _build_headers_in { 
    my $self  = shift;
    my $table = APR::Table::make( $self->_apr_pool, 64 );

    $self->plack_request->headers->scan( sub {
        $table->add( @_ );
    } );

   return $table;
}

sub _build_filename {
    my $self = shift;

    my $paf = Plack::App::File->new(
        root => $self->root
    );
    my ($file, $path) = $paf->locate_file( $self->env );

    return undef if ref $file;  # some sort of error
    return $file;
}

# Plack methods
sub finalize { 
    my $self     = shift;
    my $response = $self->plack_response;
    my $handler_status = $self->handler_status();

    # Set these headers if we handled it. mod_perl will happily send headers
    # stacked up in ->headers_out() with a ->status() set to 30x or 404, if
    # your handler returns OK.
    # FIXME - check how apache merges duplicates in headers_out/err_headers_out
    # For now, assume that the observed behaviour for Cookies headers is general
    my %seen;
    my $headers = $response->headers();
    my $merge = sub {
        if ($seen{$_[0]}++) {
            $headers->push_header(@_);
        } else {
            $headers->header(@_);
        }
        1;
    };

    $self->headers_out->do($merge)
        if $handler_status == OK || $handler_status == DONE;
    $self->err_headers_out->do($merge);

    return $response->finalize;
};

# Apache methods

sub args {
    my $self = shift;
    return $self->plack_request->env->{QUERY_STRING};
}

sub hostname {
    my $self = shift;

    return $self->env->{SERVER_NAME};
}

sub subprocess_env {
    my $self = shift;

    if (@_ == 1) {
        return $self->_subprocess_env->get( @_ );
    }

    if (@_ == 2) {
        return $self->_subprocess_env->set( @_ );
    }

    if (defined wantarray) {
        return $self->_subprocess_env;
    }

    $self->_subprocess_env->do( sub { $ENV{ $_[0] } = $_[1]; 1 } );
    return;
}

sub dir_config {
    my $self = shift;

    if (@_ == 0) {
        return $self->_dir_config;
    }

    if (@_ == 1) {
        return scalar $self->_dir_config->get( @_ );
    }

    my ($key, $value) = @_;

    if (defined $value) {
        $self->_dir_config->set( $value );
    } else {
        $self->_dir_config->clear( $value );
    }
    return;
}

sub document_root {
    my $self = shift;
    return $self->root;
}

sub pnotes {
    my $self = shift;
    my $key  = shift;
    my $old = $self->env->{$NS.'.pnotes'}->{$key};

    if (@_) {
        $self->env->{$NS.'.pnotes'}->{$key} = shift;
    }

    return $old;
}

sub notes {
    my $self = shift;
    if (!@_) {
        return Plack::App::FakeApache::Notes->new(env => $self->env);
    }

    my $key  = shift;
    my $old = $self->env->{$NS.'.notes'}->{$key};

    if (@_) {
        $self->env->{$NS.'.notes'}->{$key} = "".shift;
    }

    return $old;
}

# this is strictly mocking Apache::Connection, and only partially
sub connection {
    my $self = shift;

    return Plack::App::FakeApache::Connection->new(
        remote_ip => $self->plack_request->address,
        log       => $self->log,
    );
}

sub read {
    my $self = shift;
    my ($buffer, $length, $offset) = @_; # ... but use $_[0] for buffer

    my $request = $self->plack_request;

    # Is this needed? Intrudes on a Plack::Request private methodf...
    unless ($request->env->{'psgix.input.buffered'}) {
        $request->_parse_request_body;

        # Sets psgix.input.buffered and rewinds.
    }

    my $fh = $request->input
        or return 0;

    return $fh->read($_[0], $length, $offset);
}

sub print {
    my $self = shift;

    my $length = 0;
    for (@_) {
        $self->_add_content($_);
        $length += length;
    }

    return $length;
}

sub write {
    my ($self, $buffer, $length, $offset) = @_;

    if (defined $length && $length == -1) {
        $self->_add_content($buffer);
        return length $buffer;
    }

    my $output = substr $buffer, $offset // 0, $length // length $buffer;

    $self->_add_content($output);
    
    return length $output;
}

sub _add_content {
    my $self = shift;

    push @{ $self->plack_response->body }, @_;
}

sub rflush {
    1;
}

sub uri
{
    my $self = shift;
    return $self->plack_request->uri->path;
}

sub construct_url
{
    my $self = shift;
    my $path = shift;
    my $uri  = URI->new($self->plack_request->uri);
    $uri->path($path) if $path;
    return $uri->as_string;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
