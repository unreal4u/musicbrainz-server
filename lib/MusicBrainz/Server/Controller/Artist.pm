package MusicBrainz::Server::Controller::Artist;

use strict;
use warnings;

use base 'Catalyst::Controller';

use MusicBrainz::Server::Adapter qw(Google);
use ModDefs;
use UserSubscription;

=head1 NAME

MusicBrainz::Server::Controller::Artist - Catalyst Controller for working
with Artist entities

=head1 DESCRIPTION

The artist controller is used for interacting with
L<MusicBrainz::Server::Artist> entities - both read and write. It provides
views to the artist data itself, and a means to navigate to a release
that is attributed to a certain artist.

=head1 METHODS

=head2 READ ONLY PAGES

The follow pages can are all read only.

=head2 artist

Private chained action for loading enough information on the artist header

=cut

sub artist : Chained('/') CaptureArgs(1)
{
    my ($self, $c, $mbid) = @_;

    if (defined $mbid)
    {
        my $artist = $c->model('Artist')->load($mbid);

        if ($artist->id == ModDefs::DARTIST_ID)
        {
            $c->error("You cannot view the special artist 'DELETED ARTIST'");
            $c->detach;
        }

        $c->stash->{artist} = $artist;
    }
    else
    {
        $c->error("No MBID/row ID given.");
        $c->detach;
    }
}

=head2 similar

Display artists similar to this artist

=cut

sub similar : Chained('artist')
{
    my ($self, $c) = @_;
    my $artist = $c->stash->{artist};

    $c->stash->{similar_artists} = $c->model('Artist')->find_similar_artists($artist);
}

=head2 google

Search Google for this artist

=cut

sub google : Chained('artist')
{
    my ($self, $c) = @_;
    my $artist = $c->stash->{artist};

    $c->response->redirect(Google($artist->name));
}

=head2 tags

Show all of this artists tags

=cut

sub tags : Chained('artist')
{
    my ($self, $c) = @_;
    my $artist = $c->stash->{artist};

    $c->stash->{tagcloud} = $c->model('Tag')->generate_tag_cloud($artist);
}

=head2 relations

Shows all the entities (except track) that this artist is related to.

=cut

sub relations : Chained('artist')
{
    my ($self, $c) = @_;
    my $artist = $c->stash->{artist};

    $c->stash->{relations} = $c->model('Relation')->load_relations($artist, to_type => [ 'artist', 'url', 'label', 'album' ]);
}

=head2 appearances

Display a list of releases that an artist appears on via advanced
relations.

=cut

sub appearances : Chained('artist')
{
    my ($self, $c) = @_;
    my $artist = $c->stash->{artist};

    $c->stash->{releases} = $c->model('Release')->find_linked_albums($artist);
}

=head2 perma

Display the perma-link for a given artist.

=cut

# Empty because everything we need is in added to the stash with sub artist.
sub perma : Chained('artist') { }

=head2 details

Display detailed information about a specific artist.

=cut

# Empty because everything we need is in added to the stash with sub artist.
sub details : Chained('artist') { }

=head2 aliases

Display all aliases of an artist, along with usage information.

=cut

sub aliases : Chained('artist')
{
    my ($self, $c) = @_;
    my $artist = $c->stash->{artist};

    $c->stash->{aliases}  = $c->model('Alias')->load_for_entity($artist);
}

=head2 show

Shows an artist's main landing page.

This page shows the main releases (by default) of an artist, along with a
summary of advanced relations this artist is involved in. It also shows
folksonomy information (tags).

=cut

sub show : PathPart('') Chained('artist')
{
    my ($self, $c) = @_;
    my $artist = $c->stash->{artist};

    my $show_all = $c->req->query_params->{show_all} || 0;

    $c->stash->{tags}       = $c->model('Tag')->top_tags($artist);
    $c->stash->{releases}   = $c->model('Release')->load_for_artist($artist, $show_all);
    $c->stash->{relations}  = $c->model('Relation')->load_relations($artist, to_type => [ 'artist', 'url', 'label', 'album' ]);
    $c->stash->{annotation} = $c->model('Annotation')->load_latest_annotation($artist);

    # Decide how to display the data
    $c->stash->{template} = defined $c->request->query_params->{full} ? 
                                'artist/full.tt' :
                                'artist/compact.tt';
}


=head2 WRITE METHODS

These methods write to the database (create/update/delete)

=head2 create

When given a GET request this displays a form allowing the user to enter
data, creating a new artist. If a POST request is received, the data
is validated and if validation succeeds, the artist is entered into the
MusicBrainz database.

The heavy work validating the form and entering data into the database
is done via L<MusicBrainz::Server::Form::Artist>

=cut

sub create : Local
{
    my ($self, $c) = @_;

    $c->forward('/user/login');

    my $form = $c->form(undef, 'Artist::Create');
    $form->context($c);

    return unless $c->form_posted && $form->validate($c->req->params);

    my @mods = $form->insert;

    $c->flash->{ok} = "Thanks! The artist has been added to the " .
                      "database, and we have redirected you to " .
                      "their landing page";

    # Make sure that the moderation did go through, and redirect to
    # the new artist
    my @add_mods = grep { $_->type eq ModDefs::MOD_ADD_ARTIST } @mods;

    die "Artist could not be created"
        unless @add_mods;

    # we can't use entity_url because that would require loading the new artist
    # or creating a mock artist - both are messier than this slightly
    # hacky solution
    $c->response->redirect($c->uri_for('/artist', $add_mods[0]->row_id));
}

=head2 edit

Allows users to edit the data about this artist.

When viewed with a GET request, the user is displayed a form filled with
the current artist data. When a POST request is received, the data is
validated and if it passed validation is the updated data is entered
into the MusicBrainz database.

=cut 

sub edit : Chained('artist')
{
    my ($self, $c, $mbid) = @_;
    
    $c->forward('/user/login');

    my $artist = $c->stash->{artist};

    my $form = $c->form($artist, 'Artist::Edit');
    $form->context($c);

    return unless $c->form_posted && $form->validate($c->req->params);

    $form->insert;

    $c->flash->{ok} = "Thanks, your artist edit has been entered " .
                      "into the moderation queue";

    $c->response->redirect($c->entity_url($artist, 'show'));
}

=head2 merge

Merge 2 artists into a single artist

=cut

sub merge : Chained('artist')
{
    my ($self, $c) = @_;

    $c->forward('/user/login');
    $c->forward('/search/filter_artist');

    $c->stash->{template} = 'artist/merge_search.tt';
}

sub merge_into : Chained('artist') PathPart('merge-into') Args(1)
{
    my ($self, $c, $new_mbid) = @_;

    $c->forward('/user/login');

    my $artist     = $c->stash->{artist};
    my $new_artist = $c->model('Artist')->load($new_mbid);

    my $form = $c->form($artist, 'Artist::Merge');
    $form->context($c);

    $c->stash->{new_artist} = $new_artist;
    $c->stash->{template  } = 'artist/merge.tt';

    return unless $c->form_posted && $form->validate($c->req->params);

    $form->insert($new_artist);

    $c->flash->{ok} = "Thanks, your artist edit has been entered " .
                      "into the moderation queue";

    $c->response->redirect($c->entity_url($new_artist, 'show'));
}

=head2 subscribe

Allow a moderator to subscribe to this artist

=cut

sub subscribe : Chained('artist')
{
    my ($self, $c) = @_;
    my $artist = $c->stash->{artist};

    $c->forward('/user/login');

    my $us = UserSubscription->new($c->mb->{DBH});
    $us->SetUser($c->user->id);
    $us->SubscribeArtists($artist);

    $c->forward('subscriptions');
}

=head2 unsubscribe

Unsubscribe from an artist

=cut

sub unsubscribe : Chained('artist')
{
    my ($self, $c) = @_;
    my $artist = $c->stash->{artist};

    $c->forward('/user/login');

    my $us = UserSubscription->new($c->mb->{DBH});
    $us->SetUser($c->user->id);
    $us->UnsubscribeArtists($artist);

    $c->forward('subscriptions');
}

=head2 show_subscriptions

Show all users who are subscribed to this artist, and have stated they
wish their subscriptions to be public

=cut

sub subscriptions : Chained('artist')
{
    my ($self, $c) = @_;

    $c->forward('/user/login');

    my $artist = $c->stash->{artist};

    my @all_users = $artist->GetSubscribers;
    
    my @public_users;
    my $anonymous_subscribers;

    for my $uid (@all_users)
    {
        my $user = $c->model('User')->load_user({ id => $uid });

        my $public = UserPreference::get_for_user("subscriptions_public", $user);
        my $is_me  = $c->user_exists && $c->user->id == $user->id;

        if ($is_me) { $c->stash->{user_subscribed} = $is_me; }
        
        if ($public || $is_me)
        {
            push @public_users, $user;
        }
        else
        {
            $anonymous_subscribers++;
        }
    }

    $c->stash->{subscribers          } = \@public_users;
    $c->stash->{anonymous_subscribers} = $anonymous_subscribers;

    $c->stash->{template} = 'artist/subscribe.tt';
}

=head2 add_release

Add a release to this artist

=cut

sub add_release : Local
{
    my ($self, $c) = @_;
    die "This is a stub method";
}

=head2 import

Import a release from another source (such as FreeDB)

=cut

sub import : Local
{
    my ($self, $c) = @_;
    die "This is a stub method";
}

=head2 add_non_album

Add non-album tracks to this artist (creating the special non-album
release if necessary)

=cut

sub add_non_album : Chained('artist')
{
    my ($self, $c) = @_;

    $c->forward('/user/login');

    my $artist = $c->stash->{artist};
    
    my $form = $c->form($artist, 'Artist::AddNonAlbumTrack');
    $form->context($c);

    return unless $c->form_posted && $form->validate($c->req->params);

    $form->insert;

    $c->flash->{ok} = 'Thanks, your edit has been entered into the moderation queue';

    $c->response->redirect($c->entity_url($artist, 'show'));
}

=head2 change_quality

Change the data quality of this artist

=cut

sub change_quality : Chained('artist')
{
    my ($self, $c, $mbid) = @_;

    $c->forward('/user/login');

    my $artist = $c->stash->{artist};

    my $form = $c->form($artist, 'Artist::DataQuality');
    $form->context($c);

    return unless $c->form_posted && $form->validate($c->req->params);

    $form->insert;

    $c->flash->{ok} = "Thanks, your artist edit has been entered " .
                      "into the moderation queue";

    $c->response->redirect($c->entity_url($artist, 'show'));
}

=head2 add_release

Allow users to add a new release to this artist.

This is a multipage wizard which consists of specifying the track count,
then the track information. Following screens allow the user to confirm
the artists/labels (or create them), and then finally enter an edit note.

=cut

sub add_release : Chained('artist')
{
    my ($self, $c) = @_;

    my $step = $c->req->params->{step} || 0;
    $c->session->{wizard__step} = $step;

    use Switch 'fallthrough';
    switch ($step)
    {
        case 0
        {
            $c->forward('add_release_track_count');

            # Step one was submitted and validated, lets move to the next step
            $c->stash->{wizard__step}++;
            $c->forward('add_release_tracks');
        }

        case 1
        {
            $c->forward('add_release_tracks');
        }

        case 2
        {

        }
    }
}

sub add_release_track_count : Private
{
    my ($self, $c) = @_;

    my $form = $c->form(undef, 'AddRelease::TrackCount');
    $c->stash->{template} = 'add_release/track_count.tt';

    $c->detach unless $c->form_posted && $form->validate($c->req->params);

    $c->session->{wizard__add_release__track_count} = $form->value('track_count');
}

sub add_release_tracks : Private
{
    my ($self, $c) = @_;

    $c->stash->{template} = 'add_release/tracks.tt';
}

=head1 LICENSE 

This software is provided "as is", without warranty of any kind, express or
implied, including  but not limited  to the warranties of  merchantability,
fitness for a particular purpose and noninfringement. In no event shall the
authors or  copyright  holders be  liable for any claim,  damages or  other
liability, whether  in an  action of  contract, tort  or otherwise, arising
from,  out of  or in  connection with  the software or  the  use  or  other
dealings in the software.

GPL - The GNU General Public License    http://www.gnu.org/licenses/gpl.txt
Permits anyone the right to use and modify the software without limitations
as long as proper  credits are given  and the original  and modified source
code are included. Requires  that the final product, software derivate from
the original  source or any  software  utilizing a GPL  component, such  as
this, is also licensed under the GPL license.

=cut

1;
