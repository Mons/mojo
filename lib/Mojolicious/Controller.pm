package Mojolicious::Controller;

use strict;
use warnings;

use base 'MojoX::Dispatcher::Routes::Controller';

use Mojo::ByteStream;
use Mojo::Exception;
use Mojo::URL;

require Carp;

our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;

    # Method
    my ($method) = $AUTOLOAD =~ /(\w+)$/;

    # Helper
    Carp::croak(qq/Helper "$method" not found/)
      unless my $helper = $self->app->renderer->helper->{$method};

    # Run
    return $self->$helper(@_);
}

sub DESTROY { }

sub client { shift->app->client }

sub finish {
    my $self = shift;

    # WebSocket check
    Carp::croak('No WebSocket connection to finish')
      unless $self->tx->is_websocket;

    # Finish WebSocket
    $self->tx->finish;
}

sub finished {
    my ($self, $cb) = @_;

    # Transaction finished
    $self->tx->finished(sub { shift and $self->$cb(@_) });
}

# DEPRECATED in Comet!
sub helper {
    my $self = shift;

    # Name
    return unless my $name = shift;

    # Run
    return $self->$name(@_);
}

sub receive_message {
    my $self = shift;

    # WebSocket check
    Carp::croak('No WebSocket connection to receive messages from')
      unless $self->tx->is_websocket;

    # Callback
    my $cb = shift;

    # Receive
    $self->tx->receive_message(sub { shift and $self->$cb(@_) });

    # Rendered
    $self->rendered;

    return $self;
}

sub redirect_to {
    my $self = shift;

    # Response
    my $res = $self->res;

    # Code
    $res->code(302);

    # Headers
    my $headers = $res->headers;
    $headers->location($self->url_for(@_)->to_abs);
    $headers->content_length(0);

    # Rendered
    $self->rendered;

    return $self;
}

# Mamma Mia! The cruel meatball of war has rolled onto our laps and ruined
# our white pants of peace!
sub render {
    my $self = shift;

    # Template as single argument
    my $stash = $self->stash;
    my $template;
    $template = shift if @_ % 2 && !ref $_[0];

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Template
    $args->{template} = $template if $template;
    unless ($stash->{template} || $args->{template}) {

        # Default template
        my $controller = $args->{controller} || $stash->{controller};
        my $action     = $args->{action}     || $stash->{action};

        # Normal default template
        if ($controller && $action) {
            $self->stash->{template} =
              join('/', split(/-/, $controller), $action);
        }

        # Try the route name if we don't have controller and action
        elsif ($self->match && (my $name = $self->match->endpoint->name)) {
            $self->stash->{template} = $name;
        }
    }

    # Render
    my ($output, $type) = $self->app->renderer->render($self, $args);

    # Failed
    return unless defined $output;

    # Partial
    return $output if $args->{partial};

    # Response
    my $res = $self->res;

    # Status
    $res->code($stash->{status}) if $stash->{status};
    $res->code(200) unless $res->code;

    # Output
    $res->body($output) unless $res->body;

    # Type
    my $headers = $res->headers;
    $headers->content_type($type) unless $headers->content_type;

    # Rendered
    $self->rendered;

    # Success
    return 1;
}

sub render_data {
    my $self = shift;
    my $data = shift;

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Data
    $args->{data} = $data;

    return $self->render($args);
}

sub render_exception {
    my ($self, $e) = @_;

    # Exception
    $e = Mojo::Exception->new($e) unless ref $e;

    # Error
    $self->app->log->error($e);

    # Render exception template
    my $options = {
        template         => 'exception',
        format           => 'html',
        handler          => undef,
        status           => 500,
        exception        => $e,
        'mojo.exception' => 1
    };
    $self->app->static->serve_500($self)
      if $self->stash->{'mojo.exception'} || !$self->render($options);

    # Rendered
    $self->rendered;
}

sub render_inner {
    my ($self, $name, $content) = @_;

    # Initialize
    my $stash = $self->stash;
    $stash->{'mojo.content'} ||= {};
    $name ||= 'content';

    # Set
    $stash->{'mojo.content'}->{$name}
      ||= ref $content eq 'CODE' ? $content->() : $content
      if defined $content;

    # Get
    $content = $stash->{'mojo.content'}->{$name};
    $content = '' unless defined $content;
    return Mojo::ByteStream->new("$content");
}

sub render_json {
    my $self = shift;
    my $json = shift;

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # JSON
    $args->{json} = $json;

    return $self->render($args);
}

sub render_not_found {
    my ($self, $resource) = @_;

    # Debug
    $self->app->log->debug(qq/Resource "$resource" not found./)
      if $resource;

    # Render not found template
    my $options = {
        template  => 'not_found',
        format    => 'html',
        not_found => 1
    };
    $options->{status} = 404 unless $self->stash->{status};
    $self->app->static->serve_404($self)
      if $self->stash->{not_found} || !$self->render($options);

    # Rendered
    $self->rendered;
}

sub render_partial {
    my $self = shift;

    # Template as single argument
    my $template;
    $template = shift if (@_ % 2 && !ref $_[0]) || (!@_ % 2 && ref $_[1]);

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Template
    $args->{template} = $template if $template;

    # Partial
    $args->{partial} = 1;

    return Mojo::ByteStream->new($self->render($args));
}

sub render_static {
    my $self = shift;

    # Static
    $self->app->static->serve($self, @_);

    # Rendered
    $self->rendered;
}

sub render_text {
    my $self = shift;
    my $text = shift;

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Data
    $args->{text} = $text;

    return $self->render($args);
}

sub rendered {
    my $self = shift;

    # Resume
    $self->tx->resume;

    # Rendered
    $self->stash->{'mojo.rendered'} = 1;

    # Stash
    my $stash = $self->stash;

    # Already finished
    return $self if $stash->{'mojo.finished'};

    # Transaction
    my $tx = $self->tx;

    # Application
    my $app = $self->app;

    # Hook
    $app->plugins->run_hook_reverse(after_dispatch => $self);

    # Session
    $app->session->store($self);

    # Finished
    $stash->{'mojo.finished'} = 1;

    return $self;
}

sub send_message {
    my $self = shift;

    # WebSocket check
    Carp::croak('No WebSocket connection to send message to')
      unless $self->tx->is_websocket;

    # Send
    $self->tx->send_message(@_);

    # Rendered
    $self->rendered;

    return $self;
}

sub url_for {
    my $self = shift;
    my $target = shift || '';

    # Make sure we have a match for named routes
    $self->match(MojoX::Routes::Match->new->root($self->app->routes))
      unless $self->match;

    # Path
    if ($target =~ /^\//) {
        my $url = Mojo::URL->new->base($self->req->url->base->clone);
        return $url->parse($target);
    }

    # URL
    elsif ($target =~ /^\w+\:\/\//) { return Mojo::URL->new($target) }

    # Use match or root
    my $url = $self->match->url_for($target, @_);

    # Base
    unless ($url->is_abs) {
        $url->base($self->tx->req->url->base->clone);
        $url->base->userinfo(undef);
    }

    # Fix paths
    unshift @{$url->path->parts}, @{$url->base->path->parts};
    $url->base->path->parts([]);

    return $url;
}

sub write {
    my ($self, $chunk, $cb) = @_;

    # Callback only
    if (ref $chunk && ref $chunk eq 'CODE') {
        $cb    = $chunk;
        $chunk = undef;
    }

    # Write
    $self->res->write(
        $chunk,
        sub {

            # Cleanup
            shift;

            # Callback
            $self->$cb(@_) if $cb;
        }
    );

    # Rendered
    $self->rendered;
}

sub write_chunk {
    my ($self, $chunk, $cb) = @_;

    # Callback only
    if (ref $chunk && ref $chunk eq 'CODE') {
        $cb    = $chunk;
        $chunk = undef;
    }

    # Write
    $self->res->write_chunk(
        $chunk,
        sub {

            # Cleanup
            shift;

            # Callback
            $self->$cb(@_) if $cb;
        }
    );

    # Rendered
    $self->rendered;
}

1;
__END__

=head1 NAME

Mojolicious::Controller - Controller Base Class

=head1 SYNOPSIS

    use base 'Mojolicious::Controller';

=head1 DESCRIPTION

L<Mojolicous::Controller> is the base class for your L<Mojolicious>
controllers.
It is also the default controller class for L<Mojolicious> unless you set
C<controller_class> in your application.

=head1 ATTRIBUTES

L<Mojolicious::Controller> inherits all attributes from
L<MojoX::Dispatcher::Routes::Controller>.

=head1 METHODS

L<Mojolicious::Controller> inherits all methods from
L<MojoX::Dispatcher::Routes::Controller> and implements the following new
ones.

=head2 C<client>

    my $client = $c->client;
    
A L<Mojo::Client> prepared for the current environment.

    my $tx = $c->client->get('http://mojolicious.org');

    $c->client->post_form('http://kraih.com/login' => {user => 'mojo'});

    $c->client->get('http://mojolicious.org' => sub {
        my $client = shift;
        $c->render_data($client->res->body);
    })->process;

For async processing you can use C<finish>.

    $c->client->async->get('http://mojolicious.org' => sub {
        my $client = shift;
        $c->render_data($client->res->body);
        $c->finish;
    })->process;

=head2 C<finish>

    $c->finish;

Gracefully end WebSocket connection.

=head2 C<finished>

    $c->finished(sub {...});

Callback signaling that the transaction has been finished.

    $c->finished(sub {
        my $self = shift;
    });

=head2 C<helper>

This method is DEPRECATED, helpers can now be called like normal methods.

    $c->foo(23);

=head2 C<receive_message>

    $c = $c->receive_message(sub {...});

Receive messages via WebSocket, only works if there is currently a WebSocket
connection in progress.

    $c->receive_message(sub {
        my ($self, $message) = @_;
    });

=head2 C<redirect_to>

    $c = $c->redirect_to('named');
    $c = $c->redirect_to('named', foo => 'bar');
    $c = $c->redirect_to('/path');
    $c = $c->redirect_to('http://127.0.0.1/foo/bar');

Prepare a redirect response.

=head2 C<render>

    $c->render;
    $c->render(controller => 'foo', action => 'bar');
    $c->render({controller => 'foo', action => 'bar'});
    $c->render(text => 'Hello!');
    $c->render(template => 'index');
    $c->render(template => 'foo/index');
    $c->render(template => 'index', format => 'html', handler => 'epl');
    $c->render(handler => 'something');
    $c->render('foo/bar');
    $c->render('foo/bar', format => 'html');

This is a wrapper around L<MojoX::Renderer> exposing pretty much all
functionality provided by it.
It will set a default template to use based on the controller and action name
or fall back to the route name.
You can call it with a hash of options which can be preceded by an optional
template name.
Note that all render arguments get localized, so stash values won't be
changed after the render call.

=head2 C<render_data>

    $c->render_data($bits);

Render binary data, similar to C<render_text> but data will not be encoded.

=head2 C<render_exception>

    $c->render_exception($e);

Render the exception template C<exception.html.$handler>.
Will set the status code to C<500> meaning C<Internal Server Error>.
Takes a L<Mojo::Exception> object or error message and will fall back to
rendering a static C<500> page using L<MojoX::Renderer::Static>.

=head2 C<render_inner>

    my $output = $c->render_inner;
    my $output = $c->render_inner('content');
    my $output = $c->render_inner(content => 'Hello world!');
    my $output = $c->render_inner(content => sub { 'Hello world!' });

Contains partial rendered templates, used for the renderers C<layout> and
C<extends> features.

=head2 C<render_json>

    $c->render_json({foo => 'bar'});
    $c->render_json([1, 2, -3]);

Render a data structure as JSON.

=head2 C<render_not_found>

    $c->render_not_found;
    $c->render_not_found($resource);
    
Render the not found template C<not_found.html.$handler>.
Also sets the response status code to C<404>, will fall back to rendering a
static C<404> page using L<MojoX::Renderer::Static>.

=head2 C<render_partial>

    my $output = $c->render_partial;
    my $output = $c->render_partial(action => 'foo');
    
Same as C<render> but returns the rendered result.

=head2 C<render_static>

    $c->render_static('images/logo.png');

Render a static asset using L<MojoX::Dispatcher::Static>.

=head2 C<render_text>

    $c->render_text('Hello World!');
    $c->render_text('Hello World', layout => 'green');

Render the given content as plain text, note that text will be encoded.
See C<render_data> for an alternative without encoding.

=head2 C<rendered>

    $c->rendered;

Disable automatic rendering for response and run C<after_dispatch> plugin
hook.
Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<send_message>

    $c = $c->send_message('Hi there!');

Send a message via WebSocket, only works if there is currently a WebSocket
connection in progress.

=head2 C<url_for>

    my $url = $c->url_for;
    my $url = $c->url_for(controller => 'bar', action => 'baz');
    my $url = $c->url_for('named', controller => 'bar', action => 'baz');

Generate a L<Mojo::URL> for the current or a named route.

=head2 C<write>

    $c->write;
    $c->write('Hello!');
    $c->write(sub {...});
    $c->write('Hello!', sub {...});

Write dynamic content matching the corresponding C<Content-Length> header
chunk wise, the optional drain callback will be invoked once all data has
been written to the kernel send buffer or equivalent.

    $c->res->headers->content_length(6);
    $c->write('Hel');
    $c->write('lo!');

Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<write_chunk>

    $c->write_chunk;
    $c->write_chunk('Hello!');
    $c->write_chunk(sub {...});
    $c->write_chunk('Hello!', sub {...});

Write dynamic content chunk wise with the C<chunked> C<Transfer-Encoding>
which doesn't require a C<Content-Length> header, the optional drain callback
will be invoked once all data has been written to the kernel send buffer or
equivalent.
An empty chunk marks the end of the stream.

    $c->write_chunk('Hel');
    $c->write_chunk('lo!');
    $c->write_chunk('');

Note that this method is EXPERIMENTAL and might change without warning!

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
