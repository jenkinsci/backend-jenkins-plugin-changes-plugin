#!/usr/bin/perl
#
# Collect and group output from report.pl to get final report output.
# @author Alan Harder (mindless@dev.java.net)
#
my $prefix = $ARGV[0];

# Write temp file with map data plus perl code for report
open(OUT, ">run.pl") or die;
print OUT "\nuse strict;\nmy (%knownRevs, %skipTag, %skipEntry, %tagMap);\n";
print OUT &parseData, ");\n\n";
open(IN, "<report.pl") or die;
print OUT <IN>;
close IN;
close OUT;

# Run report
my $time = time;
my $start = `date`; chomp($start);
my $rpt = `perl run.pl $prefix`;

# Group results and wikify
$rpt = &wikify($rpt);
$time = time - $time;
print "This is a report of unreleased changes for plugins in Hudson's subversion repository.\n",
      "It is updated once per week.\n\n", $rpt, "Generated at: $start in ",
      int($time/60), " min ", ($time%60), " sec.\n";

unlink "run.pl";

sub parseData() {
  # Parse input and convert into perl variable definitions:
  my $section = 0;
  my @mapVars = ( "skipTag", "skipEntry", "tagMap" );
  my ($mapBuf, $tokenChars) = ("%knownRevs = (\n", "[a-zA-Z0-9+._-]+");
  while (<STDIN>) {
    s/#.*$//;  # Remove inline comment
    next if /^\s*$/;
    if (/^----/) {
      $mapBuf .= ");\n%" . $mapVars[$section++] . " = (\n";
      next;
    }
    if ($section == 0) { # %knownRevs
      if (/^\s*($tokenChars)\s*\|\s*([ a-zA-Z0-9~!@%*()\[\]|;:+=,.<>\/?_-]+?)\s*$/) {
        $mapBuf .= " '$1' => '$2',\n";
      }
    } elsif ($section == 1 or $section == 2) { # %skipTag or %skipEntry
      if (/^\s*($tokenChars)\s*$/) {
        $mapBuf .= " '$1' => 1,\n";
      }
    } elsif ($section == 3) { # %tagMap
      if (/^\s*($tokenChars)\s*\|\s*($tokenChars)\s*$/) {
        $mapBuf .= " '$1' => '$2',\n";
      }
    }
  }
  return $mapBuf;
}

sub wikify {
  my ($rpt) = @_;
  my (@current, @unreleased, @other, $last);
  foreach (split /[\n\r]+/, $rpt) {
    unless (/^\|/)       { push(@$last, $_) }
    elsif (/CURRENT/)    { push(@current, $_); $last = \@current }
    elsif (/unreleased/) { push(@unreleased, $_); $last = \@unreleased }
    else                 { push(@other, $_); $last = \@other }
  }
  return "h3. Plugin Changes\n" . join("\n", @other)
         . "\n\nh3. Unreleased Plugins\n" . join("\n", @unreleased)
         . "\n\nh3. Current Plugins\n" . join("\n", @current) . "\n\n";
}

