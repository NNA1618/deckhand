# Runs Deckhand's now playing adapter inside Apple's /usr/bin/perl, a platform binary that the
# MediaRemote framework answers to. Usage: /usr/bin/perl now-playing.pl /path/to/DeckhandNowPlaying.dylib
use strict;
use warnings;
use DynaLoader;

my $path = shift @ARGV or die "usage: now-playing.pl <adapter dylib>\n";
my $lib = DynaLoader::dl_load_file($path, 0) or die "cannot load adapter: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($lib, "deckhand_now_playing_main")
    or die "adapter entry point missing: " . DynaLoader::dl_error() . "\n";
my $main = DynaLoader::dl_install_xsub("Deckhand::now_playing_main", $symbol);
&$main();
