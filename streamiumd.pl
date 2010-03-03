#!/usr/bin/perl -w
# streamiumd
# by Dave Witt, special thanks to Nathan Peterson
# streamiumd_2007@acuracars.net
# http://www.witt.tv

# Credit and thanks given to Nathan Peterson for his work in hacking the
# protocol.  Some of his original pclink.pl code used here.  Visit Nathan's
# website at http://www.siteswap.org/streamium/

# Description: This program takes your mp3s and makes them available to your
# streamium.  It is meant to make streamium access to your mp3 library simple,
# especially if you categorize your mp3s using traditional folders/directories.
# It can read .m3u (winamp) playlists (relative paths only), remember the last
# songs played for easy access the next time you power up your streamium, and
# can serve multiple clients simultaneously.  It has its own built in http
# server, so you don't need to mess around with apache.  It's as easy as having
# a linux server on the same network as your streamium and typing "streamiumd
# /your/mp3_root/".  You can run this on more than one linux server on your
# network.  "Long" lists of songs are grouped and placed in <substr-substr> for
# easier navigation.
#
# EXAMPLES CAN BE FOUND ONLINE at http://www.witt.tv/streamiumd/
#
# ..one of these days, I'll embed the docs and examples with pod.
#
# Tested on Debian Woody, Sarge, Edge, Fedora Core 4, 5, and 6.  In theory this
# should work on any linux distro that has the Perl module "MP3::Info"
# installed.
#
# I have no idea how this stacks up against the Windows equivalents.
#
# Comments and feedback are welcome.  If you like this software, let me know!

sub version {
	return "1.0";
}
# Change Log:
# Version 1.0 Released!
# 2007-09-17: Fixed bug where zombies would spawn whenever playing new songs from one of the frontends.
#

use warnings;
use strict;
use CGI qw{escape unescape};
use Getopt::Long;
use MP3::Info; # perl -MCPAN -e 'install MP3::Info'
use IO::Socket;
use IO::Select;
use Net::hostent;

my ($no_daemon, $main_root, $mp3_port, $global_myname, $showVersion);
my $result = GetOptions (
  "nodaemon"      => \$no_daemon,
  "mp3dir=s"      => \$main_root,
  "port=s"        => \$mp3_port,
  "displayname=s" => \$global_myname,
  "Version"       => \$showVersion
);


sub displayUsage {
  print "streamiumd version ".version()."\n";
  print "\n";
  print "Usage: $0 options\n";
  print "\n";
  print "Minimally:\n";
  print "$0 /your/mp3/root/directory\n";
  print "\n";
  print "Other options:\n";
  print " -m (--mp3dir)      : Use this for the mp3 root directory (or first arg from cmd line)\n";
  print " -n (--nodaemon)    : Run in the foreground (don't run as a daemon)\n";
  print " -p (--port)        : Port number to use for embedded http server (default=8080)\n";
  print " -d (--displayname) : Name to display on streamium for this server (default=\"streamiumd v".version()."\")\n";
  print "\n";
  print "Example:\n";
  print " Start the server so streamiums will see \"Dave Music\", and can\n";
  print " browse+play mp3s under /home/dave/mp3s, with the http server dishing\n";
  print " out files on http port 8081:\n";
  print "\n";
  print "   $0 /home/dave/mp3s -d \"Dave Music\" -p 8081\n";
  print "\n";
  print " The same, but watch it in action:\n";
  print "\n";
  print "   $0 /home/dave/mp3s -d \"Dave Music\" -p 8081 -n\n";
  exit;
}
if ($showVersion) { print "$0 version ".version()."\n"; exit; } # If they requested the version, print it and exit.
if (!defined($main_root))     { $main_root=$ARGV[0] || displayUsage(); }
# Set some defaults..
if (!defined($global_myname)) { $global_myname="streamiumd v".version(); }
if (!defined($mp3_port))      { $mp3_port="8080"; }

my $itemEnumerator=2;

my $root_dir='';

use POSIX 'setsid';
become_daemon() unless ($no_daemon);

#################################################################################################################################
# First, fork off a child process for the web server portion (so the devices can connect & retrieve mp3 files to play them)
my $pid = fork();
if ($pid==0) { # If we're the child..
  my $PORT = $mp3_port;

  $SIG{CHLD} = "IGNORE"; # auto-reap the zombies
  
  my $server = IO::Socket::INET->new(
    Proto     => 'tcp',
    LocalPort => $PORT,
    Listen    => SOMAXCONN,
    Reuse     => 1
  );

  die "can't setup server" unless $server;
  my $mp3_ip = $server->sockhost();
  print "[mp3 file server $0 accepting clients at http://$mp3_ip:$PORT/]\n";
  while (my $client = $server->accept()) {
    # Serve Multiple Clients at the same time by forking new processes for each request..
    my $httpd_pid = fork();
    do { $client->close; next; } if $httpd_pid; # parent loops,
    # child continues...

    $client->autoflush(1);

    my $client_ip = inet_ntoa($client->peeraddr);
    
    #############################################
    # get the http request from the streamium
    my $request = <$client>;
    print "*********\n";
    print "$request\n";
    my $startByte=0;
    for (0 .. 4) {
      my $req2 = <$client>;
      chomp $req2;
      print $req2."\n";
      # Note: the streamium can send, in the http request, an option of
      #Range: bytes=9782884-
      # ..in which case we want to send it the mp3 file starting at byte offset 9782884.
      if ($req2=~m/^Range: bytes=(\d+)-/) { $startByte=$1+0; }
    }
    print "*********\n";
    print "\n";
    #############################################

    if ($request =~ m|^GET /(.+) HTTP/1.[01]|) {
      my $reqFile = unescape($1);
      $reqFile=~s/^\/+//; # Get rid of leading slash(es) on any files requested...
      print "Request: ".$main_root."/".$reqFile."\n";
      if (-e $main_root."/".$reqFile) {
        open(my $f,"<$main_root/$reqFile") || warn "Couldn't open file: $main_root/$reqFile\n";

        ######################################################################################################################
        # Break off for a second and log the request to the top of the "history" playlist in the root for this streamium.
        my $firstLine="#EXTM3U\r\n"; # stick with m3u standards by adding the first line of the file..
        my @hist_m3u_lines = ("#EXTINF:0, \r\n", $reqFile."\r\n");
        my $numRead=0;
        if (-e "$main_root/##hist_$client_ip.m3u") {
          open(PEERM3U, "<$main_root/##hist_$client_ip.m3u"); $firstLine=<PEERM3U>;
          while (my $line = <PEERM3U>) {
            next unless ($numRead<40);
            push @hist_m3u_lines, $line; $numRead++;
          }
        } # Read in the contents of the m3u file for this streamium, if it exists, and push the lines to our hist_m3u_lines array.. but only do it 38 times, because we want our total # of entries in the history file to be 20, and each entry takes 2 lines, and we already have 2 lines for the mp3 that the streamium just requested. (Wait.. do it 40 times, in case this requested file was a dupe already in the list)

        # Remove any duplicates from the list..
        my %dupHash;
        for (my $x=0; $x<scalar(@hist_m3u_lines); $x++) {
          my $line = $hist_m3u_lines[$x];
          if (defined($dupHash{$line})) { splice @hist_m3u_lines, $x, 1; $x--; }
          else { $dupHash{$line} = 1 }
        }

        # dump the new history m3u file for this streamium.
        open(PEERM3U, ">$main_root/##hist_$client_ip.m3u");
        print PEERM3U $firstLine;
        foreach my $line (@hist_m3u_lines) { print PEERM3U $line; }
        close PEERM3U;
        #
        ######################################################################################################################

        my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size, $atime,$mtime,$ctime,$blksize,$blocks) = stat($f);
        print $client "HTTP/1.1 200 OK\r\n";
        print $client "Content-Length: $size\r\n";
        print $client "Connection: close\r\n";
        print $client "Content-Type: audio/mpeg\r\n";
        print $client "\r\n";

        binmode $f, ":raw";
        my $buf;
        sysread($f, $buf, $startByte); # Read in $startByte bytes, in case the client requested a "Range: xxx-" in the http header (see above)
        while(sysread($f, $buf, 1024)) { syswrite($client,$buf)||die "Couldn't write to client!\n"; }; 
        close $f; # try this to get rid of zombies..
      } else {
        print $client "HTTP/1.0 404 FILE NOT FOUND\n";
        print $client "Content-Type: text/plain\n\n";
        print $client "file not found\n";
      }      
    } else {
      print $client "HTTP/1.0 400 BAD REQUEST\n";
      print $client "Content-Type: text/plain\n\n";
      print $client "BAD REQUEST\n";
    }

    $client->close;
    $server->shutdown(); # This doesn't seem to do anything.. tried it to reap zombies..
    exit; # child exits
  }
  exit;
}
# End forking a child process for the web server.
#################################################################################################################################



# Will need for later
my $sock_sel = new IO::Select();

# Open UDP sock for listening
my $udpsock = new IO::Socket::INET (
  LocalPort => 42591,
  Proto     => 'udp'
);
die "Could not connect: $!" unless $udpsock;

#RESTART: # jump back to here if we need to restart the server
SERVER: while (1) { 
  my @dirs;
  my %itemToIndex;
  
  # Wait for UDP broadcast
  my $datagram;
  $udpsock->recv($datagram, 4096);
  my $clientIP = $udpsock->peerhost();
  
  # start over if not pclink client
  if($datagram !~ /^<PCLinkClient>/){ next SERVER; }
  
  # Open tcpsock connection
  my $hellosock = new IO::Socket::INET (
    PeerAddr => $clientIP,
    PeerPort => 42951,
    Proto    => 'tcp',
    #ReusePort => 1
  );
  #die "Socket could not be created.  Reason: $!\n" unless $hellosock;
  next SERVER unless $hellosock;
  
  # record my IP address for later
  my $MY_IP = $hellosock->sockhost();
  my $MP3_URL = "http://$MY_IP:$mp3_port";
  
  # Send Hello, close connection
  &hello_resp($hellosock,$global_myname);
  close ($hellosock);
  
  # Open tcpsock for listening
  my $pclinksock = new IO::Socket::INET (
    LocalPort => 42951,
    Proto     => 'tcp',
    Listen    => 1,
    Reuse     => 1
  );
  die "Could not connect: $!" unless $pclinksock;
  
  
  $sock_sel->add($udpsock);
  $sock_sel->add($pclinksock);
  
  while(1){
    # get a set of readable handles (blocks until at least one handle is ready)
    # take all readable handles in turn
    my @ready = $sock_sel->can_read();
    foreach my $rsock (@ready) {
      # if it is pclinksock then we should accept(), read, and respond
      if($rsock == $pclinksock){
        my $connection = $pclinksock->accept();
        my ($node,$elem,$index) = &get_node($connection);
        my $data = &make_xml($node,$elem,$index, $MP3_URL, \@dirs, \%itemToIndex);
  	#print $clientIP.": $data\n";
        &pclink_send($connection, $data);
        $rsock->flush(); # Dave Witt
        $pclinksock->flush(); # Dave Witt
        close($connection);
      }
      # if it is udpsock then client has reset so we must close tcp sock and restart server
      # note that it highly unlikely that some non-pclink client is broadcasting on this port, so we will take our chances.
      elsif($rsock == $udpsock){
        $sock_sel->remove($udpsock);
        $sock_sel->remove($pclinksock);
        close($pclinksock);
        next SERVER;
      }
      # otherwise wtf?!?
      else {
        die "unknown handle: $rsock";
      }
    }
  }
} # End of SERVER loop

################
## Subroutines
################

sub hello_resp {
  my ($sock,$name) = @_;
  my ($IP) = $sock->sockhost();
  my (@IP) = split /\./,$IP;

  # convert IP address to little endian
  $IP = $IP[0] + $IP[1]*0x100 + $IP[2]*0x10000 + $IP[3]*0x1000000;

  my ($hello) = "<PCLinkServer><Version>1.0</Version><VendorID>MUSICMATCH</VendorID><name>$name</name><ShortName>$name</ShortName><IP>$IP</IP><Port>51111</Port></PCLinkServer>\n";

  print $sock $hello;
  #print $hello;
  $sock->flush(); # is this necessary?
}

sub pclink_send {
  my ($sock,$data) = @_;
  my ($datalen) = length $data;
  my ($header) = "HTTP/1.0 200 OK\r\nAccept-Ranges: bytes\r\nContent-Length:$datalen\r\nContent-Type: text/xml\r\n\r\n";

  print $sock $header.$data;
  #print $header.$data;
  $sock->flush(); # is this necessary?
}

sub get_node {
  my ($sock) = @_;
  my ($datagram,$nodeid,$numelem,$fromindex);

  $sock->recv($datagram, 4096);
  #print "\n\n$datagram\n";
  $nodeid = ($datagram =~ /<nodeid>(.*)<\/nodeid>/ ? $1 : 0);
  $numelem = ($datagram =~ /<numelem>(.*)<\/numelem>/ ? $1 : 0);
  $fromindex = ($datagram =~ /<fromindex>(.*)<\/fromindex>/ ? $1 : 0);
  $sock->flush(); # Dave Witt
  print "Got node: $nodeid.  Num Elem: $numelem.  From Index: $fromindex.\n";
  return ($nodeid,$numelem,$fromindex);
}



sub parse_m3u { # This processes an m3u file and returns an array of mp3 filenames & urls in the m3u..
  my $m3uFile = shift;
  my @retArray;
  my $m3u_path = $m3uFile; { my @tmp = split(/\//, $m3uFile); pop @tmp; $m3u_path = join('/', @tmp); } # Get the path part of the m3u file to use later as a root dir just in case..
  open (INFILE, "<$m3uFile");
LINE:
  while (my $line = <INFILE>) {
    next if ($line=~/^\s*\#EXTM3U/i); # Skip it if it's the first comment line...
    my $song_length="0";
    my $ext_name='';
    if ($line=~/^\s*\#EXTINF:(-*\d+),(.*)$/) { # It's extra info about the mp3..
      $song_length = $1; # from the regex above
      $ext_name = $2; # from the regex above
      $line = <INFILE>; # Read the next line
    }
    $line=~s/(\r|\n)*$//g; # Get rid of any crlf at the end of the line
    $line=~s/\\/\//g; # Substitute backslashes for forward slashes, for the benefit of url encoding...
    if (substr($line, 0, 5) eq 'http:') { # If the line in the m3u is a url, leave it alone!
      push @retArray, $line."\t".$ext_name;
      next LINE;
    }
    if (substr($line, 0, 1) ne '/') { $line = $m3u_path."/".$line } # If the line in the m3u didn't start with a (back)slash, then the file is located in the same folder as the m3u, so make sure we know it.
    push @retArray, $line;
  }
  return @retArray;
}



sub make_xml {
  my ($node,$elem,$index, $MP3_URL, $dirsRef, $itemToIndexRef) = @_;
  my ($xml,$i,$name, $file_name, $url,$len,@files);

  $xml = "<contentdataset>";

  # Get the rows to display to the user...
  my $max_result_set = 32;
  my $result_count = 0;
  my $exclude_id_list = '0';

  my $root_dir = $dirsRef->[$node]; # This is the dir that they requested (every dir is indexed by the node #)
  #print "Node $node - $root_dir\n";

  my $breakOK=1; # Used to allow breaking up of large dirs.. but we display a "<View All>" option to the user every time we do this, and if they picked it, we want $breakOK to be 0.. # subCat2
  my $blockID = "NONE"; # subCat
  if (defined($root_dir)) { # subCat
    chomp $root_dir; # subCat
    if ($root_dir=~/^\[(\d+)\]/) { # subCat
      $blockID=$1; # subCat
      $root_dir=~s/^\[\d+\]//; # subCat
    } elsif ($root_dir=~/^\<\*\>(\d+)\//) { # subCat
      my $root_node=$1; # subCat2
      $root_dir = $dirsRef->[$root_node]; # subCat2
      $breakOK=0; # subCat2
    } # subCat
  } # subCat

  my @rootList; # The root list will contain all the files & directories
  my $is_m3u=0; # m3uDir
  if (!defined($root_dir)) { # if the directory isn't defined for the requested node, default back to the main root..
    @rootList = ( $main_root );
  } elsif ($root_dir=~/\.m3u$/i) { # m3uDir
    @rootList = parse_m3u($root_dir); # m3uDir
    $is_m3u=1; # m3uDir
  } else { # We were able to look up the actual directory by the node id.. get the list of files & directories and put them in our main list
    my $search_dir = $root_dir;
    if (!$breakOK) { $search_dir=~s/^\<\*\>//; } # subCat2
  
    # get m3u files first.. these take precedence over even dirs! # m3uDir
    opendir(DIR, $search_dir); my @m3uFiles = sort grep { /\.m3u$/i && -f "$search_dir/$_" } readdir(DIR); closedir DIR;
    for (my $x=0; $x<scalar(@m3uFiles); $x++) { $m3uFiles[$x]=$search_dir."/".$m3uFiles[$x]; }
    #old, non-portable method: my @m3uFiles = sort `find "$search_dir/" -maxdepth 1 -mindepth 1 -type f -iname "*.m3u"`;
  
    # get dirs second.. list by directory
    opendir(DIR, $search_dir); my @browseDirs = sort grep { !/^\.{1,2}$/ && -d "$search_dir/$_" } readdir(DIR); closedir DIR;
    for (my $x=0; $x<scalar(@browseDirs); $x++) { $browseDirs[$x]=$search_dir."/".$browseDirs[$x]; }
    #old, non-portable method: my @browseDirs = sort `find "$search_dir/" -maxdepth 1 -mindepth 1 -type d`; # get dirs second.. list by directory
  
    # get mp3 files third..
    opendir(DIR, $search_dir); my @mp3Files = sort grep { /\.mp3$/i && -f "$search_dir/$_" } readdir(DIR); closedir DIR;
    for (my $x=0; $x<scalar(@mp3Files); $x++) { $mp3Files[$x]=$search_dir."/".$mp3Files[$x]; }
    # old, non-portable method: my @mp3Files = sort `find "$search_dir/" -maxdepth 1 -mindepth 1 -type f -iname "*.mp3"`; # get mp3 files third.. 
    @rootList = (@m3uFiles, @browseDirs, @mp3Files); # m3uDir - modified
    # no longer necessary--since we don't use 'find' anymore, dirs and files don't have newlines anymore: chomp (@rootList);
  }

print "\n\nRoot List:\n".join("\n", @rootList)."\n\n";

  my $tot_rows = scalar(@rootList); # The total # of items in the "root"..

  if (!$is_m3u && $breakOK) { # If it's not an m3u, it's ok to subcat.. otherwise leave it alone! # m3uDir # subCat # subCat2
    # If the total # of items to display is greater than, say, 50, then it's probably not a single artist and we should probably break it up into separate "subcategory" items for easier browsing on the streamium...  identify all related lines of the program with subCat
    my $desired_rows = 10; # subCat
    my $rowLimit = 60; # subCat
    my $incrementor = sprintf('%d', $tot_rows/$desired_rows); # Break it up into 10 items.. # subCat
    if ($blockID ne "NONE") { my $blockStart = $blockID*$incrementor; @rootList = @rootList[$blockStart..$blockStart+$incrementor-1]; $tot_rows = scalar(@rootList); } # subCat
    my @subCatList; # subCat
    if ($tot_rows>$rowLimit) { # subCat
      my $blockStart = 0; # subCat
      for (my $i=0; $i<$desired_rows; $i++) { # subCat
        my $dir1 = $rootList[$blockStart]; # subCat
        my @junk = split (/\//, $dir1); my $tdir1 = pop @junk; #subCat
        my $dir2 = $rootList[$blockStart+$incrementor-1]; # subCat
        my @junk2 = split (/\//, $dir2); my $tdir2 = pop @junk2; #subCat
        my $lenDir1 = length($tdir1); # subCat
        my $lenDir2 = length($tdir2); # subCat
        my $minLen = $lenDir1; if ($lenDir2<$lenDir1) { $minLen = $lenDir2 } # subCat
        my $diffIndex = 0; # subCat
        for (my $x=0; $x<$minLen; $x++) { # subCat
          if (substr($tdir1, $x, 1) ne substr($tdir2, $x, 1)) { $diffIndex=$x; $x=$minLen; } # subCat
        } # subCat
        my $displayName; # subCat
        if ($diffIndex<=6) { # subCat
          $displayName = "<".substr($tdir1, 0, 6)."|".substr($tdir2, 0, 6).">"; # subCat
        } else { # subCat
          $displayName = "<".substr($tdir1, 0, 2)."_".substr($tdir1, $diffIndex, 2)."|".substr($tdir2, 0, 2)."_".substr($tdir2, $diffIndex, 2).">"; # subCat
        } # subCat
        push @subCatList, $displayName; # subCat
        if (!defined($itemToIndexRef->{$displayName})) { # subCat
          $dirsRef->[$itemEnumerator] = "[".$i."]".$root_dir; # subCat
          #print "Added [$i]$root_dir: $displayName\n"; # subCat
          $itemToIndexRef->{$displayName} = $itemEnumerator++; # subCat
        } # subCat
        $blockStart+=$incrementor; # subCat
      } # subCat
      $tot_rows = $desired_rows; # subCat
      @rootList = @subCatList; # subCat
      
      ############################## # subCat2
      my $viewAll = "<*>".$itemToIndexRef->{$root_dir}."/<View All>"; # subCat2
      unshift @rootList, $viewAll; # subCat2
      if (!defined($itemToIndexRef->{$viewAll})) { # subCat2
      	$dirsRef->[$itemEnumerator] = $viewAll; $itemToIndexRef->{$viewAll} = $itemEnumerator++; # subCat2
      } # subCat2
      $tot_rows++; # subCat2
      ############################## # subCat2
  
    } # subCat
  } # m3uDir # subCat


  my @showToStreamium; # This is the list we're going to return to the streamium.. it's limited to the "$index"th element and "$elem" number of elements after the index (for efficient scrolling throughlong lists.. kinda lame when you have 5000 items in the list because they have no page down or "search" feature..)
  for (my $x=$index; $x<=$index+$elem; $x++) {
    next unless ($x<$tot_rows);
    my $item = $rootList[$x]; chomp $item;
    push @showToStreamium, $item;
    if (!defined($itemToIndexRef->{$item})) {
      $dirsRef->[$itemEnumerator]=$item;
      $itemToIndexRef->{$item}=$itemEnumerator++;
    }
  }


  my $lim = 128; # For limiting the displayed characters of artist, filename, etc.. - what's the max?  Max for song # is very small.
  my $displayed_rows=0;
  #my $dir_path = get_node_path($node);
  for (my $x=0; $x<scalar(@showToStreamium); $x++) {
    my $name = $showToStreamium[$x];
    my $node_id = $itemToIndexRef->{$name};
    #if (-d $name) { # It's a dir # commented in lieu of subCat
    if ($name=~/^</ || $name=~/\.m3u$/i || -d $name) { # It's a dir or a specialized subcat.  TODO - Make some way of distinguishing subcats that's a little better than "the first char is <"..  # subCat #m3uDir
      my @dirsNames = split('/', $name);
      my $dName = pop @dirsNames;
      $xml .= "<contentdata><name>$dName</name><nodeid>$node_id</nodeid><branch/></contentdata>";
    } elsif (-e $name) { # It's a file.. I guess.
      #print "File: ".$name."\n";
      my $dir_path = $name; $dir_path=~s/^$main_root/\//;
      my @tmp_path = split(/\//, $dir_path);
      my $file_name=pop @tmp_path;
      for (my $x=0; $x<scalar(@tmp_path); $x++) { $tmp_path[$x]=escape($tmp_path[$x]); }
      my $url_dir_path = join('/', @tmp_path);
      my $url = $MP3_URL.$url_dir_path."/".escape($file_name);
      ## Split the name into component parts.. usually on the Witt network, this means artist_name_-_album_name_-_trackno_-_song_name.mp3
      my @mp3_parts = split("_-_", $file_name);
      my ($track_number, $album, $artist, $song_name);
      if (scalar(@mp3_parts)==4) {
      	my $song_name_mp3 = pop @mp3_parts;
      	$track_number = pop @mp3_parts;
      	if ((!$track_number=~/\d+/) && (scalar(@mp3_parts)>3)) { $song_name_mp3 = $song_name; $track_number = pop @mp3_parts; }
      	$song_name = $song_name_mp3;
      	$song_name=~s/\.mp3$//;
      } else {
      	$song_name = $file_name;
      	$artist = $file_name;
      	$album = $file_name;
      	$track_number= '';
      }
      # Trim the lengths so we don't crash the streamium..
      $track_number = substr($track_number, 0, 10);
      my $sn_length = length($song_name);
      if ($sn_length>27) { # streamium limit is 30 but we want enough room to put track # using 3 chars
      	my @junk = split('_-_', $song_name);
      	$song_name = pop @junk;
      	my $sn_length = length($song_name);
      	if ($sn_length>27) { # Still greater?  Chop it down.
      	  # Keep the first 5, two dots, and last 20..
      	  $song_name = substr($song_name, 0, 5)."..".substr($song_name, -20);
      	}
      }
      
      if ($track_number=~/\d+/) { $song_name = $track_number." ".$song_name; } # If the track # is non-blank, use it as part of the song name
      #$song_name = substr($song_name, 0, $lim); # Limit not needed?
      #$artist = substr($artist, 0, $lim);       # Limit not needed?
      #$album = substr($album, 0, $lim);         # Limit not needed?
      print "$url\n";
      my $info = get_mp3info($name); # get the mp3 info using MP3::Info module
      #printf "$file length is %d:%d\n", $info->{MM}, $info->{SS};
      # TODO: Maybe (if my mind changes about ID3 tags) use ID3 info instead of the parsed track/album/artist/song instead, if ID3 exists..
      my $song_length=($info->{MM}||"0")*60+($info->{SS}||"0");
      $xml .= "<contentdata><name>$song_name</name><nodeid>$node_id</nodeid><playable/><url>$url</url>";
      $xml .= "<title>$song_name</title><album>$album</album><trackno>$track_number</trackno><artist>$artist</artist>";
      $xml .= "<genre></genre><year></year><bitrate>128</bitrate><playlength>$song_length</playlength></contentdata>";

    } else { # Not a file or a directory.. must be a url or something.. just pass through.
      my $url = $name;
      # Kludge for internet radio entries in m3u files.. they contain tab, so split the "show to streamium" as the second param
      if ($name=~/\t/) { ($url, $name) = split(/\t/, $name); }

      $xml.="<contentdata><name>$name</name><nodeid>$node_id</nodeid><playable/><url>$url</url>";
      $xml .= "<title>$name</title><album>$name</album><trackno>1</trackno><artist>$name</artist>";
      $xml .= "<genre></genre><year></year><bitrate>128</bitrate><playlength>1000</playlength></contentdata>";
    }
    $displayed_rows++;
  }
  $xml .= "<totnumelem>$tot_rows</totnumelem><fromindex>$index</fromindex><numelem>$displayed_rows</numelem><alphanumeric/></contentdataset>\n";
  #print "XML:\n\n*******************\n$xml\n*******************\n\n";
  return $xml;
}

sub become_daemon {
  die "Can't fork" unless defined (my $child = fork);
  exit 0 if $child;  #parent dies
  setsid();       # become session leader
  open(STDIN, "</dev/null");
  open(STDOUT, ">/dev/null");
  open(STDERR, ">&STDOUT");
  chdir '/';   # change working directory
  umask(0);    # forget file mode creation mask
  $ENV{PATH} = '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin';
  return $$;
}


