package Homelab::DriveWebUI::App;

use Mojo::Base 'Mojolicious', -signatures;
use Mojo::File qw(path);
use YAML::XS qw(LoadFile);
use Carp qw(croak);

use Homelab::DriveWebUI::Helper::API;

sub startup ($self) {
    my $config_file = $ENV{HOMELAB_DRIVE_WEB_UI_CONFIG} // '/etc/homelab/drive-web-ui/drive-ui.yml';
    my $cfg = LoadFile($config_file);
    $self->config($cfg);

    # Template and static asset paths — override with HOMELAB_DRIVE_WEB_UI_HOME for development
    my $home = path($ENV{HOMELAB_DRIVE_WEB_UI_HOME} // '/usr/share/homelab-drive-web-ui');
    push @{$self->renderer->paths}, $home->child('templates')->to_string;
    push @{$self->static->paths},   $home->child('public')->to_string;

    # Session: signed cookie — secrets MUST be identical across all drive servers
    croak 'secrets array required in drive-ui.yml (must match all drive servers)'
        unless $cfg->{secrets} && ref $cfg->{secrets} eq 'ARRAY';
    $self->secrets($cfg->{secrets});
    $self->sessions->cookie_name('homelab-drive');
    $self->sessions->secure($cfg->{session}{secure} // 1);
    $self->sessions->default_expiration($cfg->{session}{expiry} // 86_400 * 7);

    # Large file support — must be set before any requests are handled
    # MOJO_TMPDIR needs to be on a volume with at least 10GB free (receives the full upload
    # before streaming it to api.example.com). Falls back to system /tmp if unset.
    $ENV{MOJO_MAX_MESSAGE_SIZE} = $cfg->{upload}{max_size} // 10_737_418_240;  # 10GB
    if (my $tmpdir = $cfg->{upload}{tmpdir}) {
        $ENV{MOJO_TMPDIR} = $tmpdir;
    }

    # Hypnotoad — proxy => 1 trusts X-Forwarded-For from nginx (required for multi-server)
    my $srv = $cfg->{server} // {};
    $self->config(hypnotoad => {
        listen            => [$srv->{listen}   // 'http://127.0.0.1:2501'],
        pid_file          => $srv->{pid_file}  // '/var/lib/homelab/drive-ui-hypnotoad.pid',
        workers           => $srv->{workers}   // 4,
        proxy             => 1,
        heartbeat_timeout => 3600,   # allow up to 1h for large file uploads/transfers
        inactivity_timeout => 3600,
    });

    # Helpers
    $self->helper(api => sub ($c) {
        Homelab::DriveWebUI::Helper::API->new(
            base_url      => $c->app->config->{api}{base_url} // 'https://api.example.com',
            jwt           => $c->session('jwt'),
            refresh_token => $c->session('refresh_token'),
            on_refresh    => sub ($new_jwt, $new_refresh) {
                $c->session(jwt           => $new_jwt);
                $c->session(refresh_token => $new_refresh);
            },
        );
    });
    $self->helper(format_size => \&_format_size);
    $self->helper(format_date => \&_format_date);
    $self->helper(file_icon   => \&_file_icon);
    $self->helper(is_htmx    => sub ($c) {
        $c->req->headers->header('HX-Request') ? 1 : 0;
    });

    # Device detection — sets device_class stash ('mobile', 'tablet', 'desktop')
    # on every request so templates can add the right body class.
    # "Request Desktop Version" in mobile browsers sends a desktop UA and
    # automatically gets the desktop layout — no extra handling needed.
    $self->hook(before_dispatch => sub ($c) {
        my $ua = $c->req->headers->user_agent // '';
        if ($ua =~ /(?:iPhone|iPod|Android.*Mobile|BlackBerry|IEMobile|Opera Mini)/i) {
            $c->stash(device_class => 'mobile');
        } elsif ($ua =~ /(?:iPad|Android(?!.*Mobile)|Tablet)/i) {
            $c->stash(device_class => 'tablet');
        } else {
            $c->stash(device_class => 'desktop');
        }
    });

    # Routes
    my $r = $self->routes;
    $r->namespaces(['Homelab::DriveWebUI::Controller']);

    # Health check — no auth, used by nginx upstream health monitoring
    $r->get('/health' => sub ($c) { $c->render(text => 'ok', status => 200) });

    # Auth routes (no guard)
    $r->get('/login')->to('auth#login_form');
    $r->post('/login')->to('auth#login');
    $r->post('/logout')->to('auth#logout');
    $r->get('/')->to(cb => sub ($c) { $c->redirect_to('/drive') });

    # Protected routes — Auth#check is the under bridge
    my $p = $r->under('/')->to('auth#check');
    $p->get('/drive')->to('files#browser');
    $p->get('/drive/files')->to('files#file_rows');
    $p->get('/drive/breadcrumb')->to('files#breadcrumb');
    $p->get('/drive/quota')->to('files#quota_bar');
    $p->post('/drive/upload')->to('files#upload');
    $p->get('/drive/thumbnail/:id')->to('files#thumbnail');
    $p->get('/drive/slide-show-image/:id')->to('files#slide_show_image');
    $p->get('/drive/download/:id')->to('files#download');
    $p->delete('/drive/files/:id')->to('files#delete');
    $p->patch('/drive/files/:id')->to('files#update');
    $p->post('/drive/files/:id/copy')->to('files#copy');
    $p->get('/drive/trash')->to('files#trash');
    $p->delete('/drive/trash')->to('files#empty_trash');
    $p->post('/drive/files/:id/restore')->to('files#restore');
    $p->get('/drive/tree.json')->to('directories#tree_json');
    $p->post('/drive/bulk/trash')->to('directories#bulk_trash');
    $p->post('/drive/bulk/move')->to('directories#bulk_move');
    $p->post('/drive/bulk/restore')->to('files#bulk_restore');
    $p->post('/drive/zip')->to('files#zip');
    $p->post('/drive/directories')->to('directories#create');
    $p->delete('/drive/directories/:id')->to('directories#delete');
    $p->patch('/drive/directories/:id')->to('directories#update');

    # Sharing routes (protected — must be logged in)
    $p->post('/drive/files/:id/share')->to('sharing#share_file');
    $p->post('/drive/directories/:id/share')->to('sharing#share_dir');
    $p->get('/drive/shares')->to('sharing#list_my_shares');
    $p->delete('/drive/shares/:id')->to('sharing#revoke');
    $p->get('/drive/shared-with-me')->to('sharing#shares_with_me');

    # Public share routes (no auth required)
    $r->get('/s/:token')->to('sharing#public_view');
    $r->get('/s/:token/download')->to('sharing#public_download');
    $r->get('/s/:token/files/:file_uuid/download')->to('sharing#public_dir_file_download');
}

sub _format_size ($c, $bytes) {
    return '—' unless defined $bytes;
    return sprintf('%.1f PB', $bytes / 1_125_899_906_842_624) if $bytes >= 1_125_899_906_842_624;
    return sprintf('%.1f TB', $bytes / 1_099_511_627_776)     if $bytes >= 1_099_511_627_776;
    return sprintf('%.1f GB', $bytes / 1_073_741_824)         if $bytes >= 1_073_741_824;
    return sprintf('%.1f MB', $bytes / 1_048_576)             if $bytes >= 1_048_576;
    return sprintf('%.1f KB', $bytes / 1_024)                 if $bytes >= 1_024;
    return "$bytes B";
}

sub _format_date ($c, $iso) {
    return '—' unless $iso;
    $iso =~ s/T/ /;
    $iso =~ s/\.\d+//;
    $iso =~ s/Z$//;
    return $iso;
}

sub _file_icon ($c, $mime) {
    return '' unless $mime;
    return 'img'   if $mime =~ m{^image/};
    return 'audio' if $mime =~ m{^audio/};
    return 'video' if $mime =~ m{^video/};
    return 'text'  if $mime =~ m{^text/};
    return 'zip'   if $mime =~ m{/(zip|gzip|x-tar|x-bzip|x-7z)};
    return 'pdf'   if $mime eq 'application/pdf';
    return 'file';
}

1;
