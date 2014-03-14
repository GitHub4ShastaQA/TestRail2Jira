#!/usr/bin/env perl

use strict;
use warnings;

use JSON;
use LWP::UserAgent;

$TestRail::user    = '';
$TestRail::pass    = '';
$TestRail::project = '';
$TestRail::suite   = '';
$TestRail::api     = '';

$Jira::user        = '';
$Jira::pass        = '';
$Jira::project_key = '';
$Jira::api         = '';


my $ua = LWP::UserAgent->new();
my($req, $res);

my $project = eval
{
	$req = HTTP::Request->new(GET => $TestRail::api.'get_projects');
	$req->content_type('application/json');
	$req->authorization_basic($TestRail::user,$TestRail::pass);
	$res = $ua->request($req);
	warn $res unless $res->is_success;
	return decode_json($res->content);
};

($project) = map { $_->{'id'} } grep { $_->{'name'} =~ /$TestRail::project/ } @$project;

my $suite = eval
{
	$req = HTTP::Request->new(GET => $TestRail::api.'get_suites/'.$project);
	$req->content_type('application/json');
	$req->authorization_basic($TestRail::user,$TestRail::pass);
	$res = $ua->request($req);
	warn $res unless $res->is_success;
	return decode_json($res->content);
};

($suite) = map {$_->{'id'}} grep {$_->{'name'} =~ /$TestRail::suite/} @$suite;

my $sections = eval
{
	$req = HTTP::Request->new(GET => $TestRail::api.'get_sections/'.$project.'&suite_id='.$suite);
	$req->content_type('application/json');
	$req->authorization_basic($TestRail::user,$TestRail::pass);
	$res = $ua->request($req);
	warn $res unless $res->is_success;
	return decode_json($res->content);
};

my %sections = map {($_->{'id'}, $_);} @$sections;

my $cases = eval
{
	$req = HTTP::Request->new(GET => $TestRail::api.'get_cases/'.$project.'&suite_id='.$suite);
	$req->content_type('application/json');
	$req->authorization_basic($TestRail::user,$TestRail::pass);
	$res = $ua->request($req);
	warn $res unless $res->is_success;
	return decode_json($res->content);
};

my $meta = eval
{
	$req = HTTP::Request->new(GET => $Jira::api.'issue/createmeta?projectKeys='.$Jira::project_key);
	$req->content_type('application/json');
	$req->authorization_basic($Jira::user,$Jira::pass);
	$res = $ua->request($req);
	warn $res unless $res->is_success;
	return decode_json($res->content);
};

my %stories;
my @bugs;
my %issuetype;
for(@{$meta->{'projects'}[0]{'issuetypes'}})
{
	$issuetype{$_->{'name'}} = $_->{'id'};
}

foreach my $case (@$cases)
{
	no warnings qw{uninitialized};
	my $story = get_story($case->{'section_id'});
	unless(exists $stories{$story})
	{
		$stories{$story} = {
			fields=>{
				project=>{id=>$meta->{'projects'}[0]{'id'}},
				summary=>'Automate test cases in '.$story.': S'.$case->{'section_id'},
				issuetype=>{
					id=>$issuetype{'Story'},
				},
				labels=>['TestRail2Jira', 'TRSection'],
				description=>
qq{	Once upon a time there were many test cases in $story. The manager of the 
land of QA decreed that they should be automated. And so the task has fallen to 
you as an Engineer of QA to automate the test cases described herein.},
				customfield_10600=>'S'.$case->{'section_id'},
			},
		};
	}
	
	$case->{'title'} =~ s/\n//g;
	
	my $sub_task = {
		fields=>{
			project=>{id=>$meta->{'projects'}[0]{'id'}},
			parent=>'S'.$case->{'section_id'},
			summary=>'Automate test case '.$case->{'title'}.': C'.$case->{'id'},
			issuetype=>{
				id=>$issuetype{'Sub-task'},
			},
			labels=>['TestRail2Jira', 'TRTestCase'],
			description=>qq{ $story / }.$case->{'title'}.qq{
			Preconditions:
			}.$case->{'custom_preconds'}.qq{
			Steps:
			}.$case->{'custom_steps'}.qq{
			
			Expected Results:
			}.$case->{'custom_expected'},
			customfield_10600=> 'C'.$case->{'id'},
		},
	};
	
	push @bugs, $sub_task;
}

my $existing_stories = {total=>1};
for(my $i = 0; $i < $existing_stories->{'total'}; $i += 50)
{
	$existing_stories = eval
	{
		$req = HTTP::Request->new(POST => $Jira::api.'search');
		$req->content_type('application/json');
		$req->authorization_basic($Jira::user,$Jira::pass);
		$req->content(
		q({
			"jql": "project = ).$Jira::project_key.q( AND labels = 'TestRail2Jira' AND labels = 'TRSection'",
			"fields": ["summary", "customfield_10600"],
			"startAt": ).$i.q(
		}));
		$res = $ua->request($req);
		warn $res unless $res->is_success;
		return decode_json($res->content);
	};

	my @keys;
	foreach my $story (@{$existing_stories->{'issues'}})
	{
		my $id = $story->{'fields'}{'customfield_10600'} //'';
		push @keys, grep 
		{
			$stories{$_}->{'fields'}{'customfield_10600'} eq $id;
		} keys %stories;
	}
	
	if(@keys)
	{
		warn "not re-adding existing sections: ".join(', ', @keys)."\n";
		delete @stories{@keys};
	}
}

# print encode_json {issueUpdates=>[@stories{keys %stories}]};

eval
{
	$req = HTTP::Request->new(POST => $Jira::api.'issue/bulk');
	$req->content_type('application/json');
	$req->authorization_basic($Jira::user,$Jira::pass);
	$req->content(encode_json {issueUpdates=>[@stories{keys %stories}]});
	$res = $ua->request($req);
	die "adding stories/sections failed" unless $res->is_success;
	return decode_json($res->content);
};

$existing_stories = {total=>1};
%stories = ();
for(my $i = 0; $i < $existing_stories->{'total'}; $i += 50)
{
	$existing_stories = eval
	{
		$req = HTTP::Request->new(POST => $Jira::api.'search');
		$req->content_type('application/json');
		$req->authorization_basic($Jira::user,$Jira::pass);
		$req->content(
		q({
			"jql": "project = ).$Jira::project_key.q( AND labels = 'TestRail2Jira' AND labels = 'TRSection'",
			"fields": ["summary", "customfield_10600"],
			"startAt": ).$i.q(
		}));
		$res = $ua->request($req);
		warn $res unless $res->is_success;
		return decode_json($res->content);
	};
	
	foreach(@{$existing_stories->{'issues'}})
	{
		my $id = $_->{'fields'}{'customfield_10600'} // '';
		$stories{$id} = $_->{'id'};
	}
}

foreach(@bugs)
{
	$_->{'fields'}{'parent'} = {id=>$stories{$_->{'fields'}{'parent'}}};
}

# print encode_json( {issueUpdates=>[@bugs[0..4]]} ), "\n\n";

my $existing_bugs = {total=>1};
for(my $i = 0; $i < $existing_bugs->{'total'}; $i += 50)
{
	$existing_bugs = eval
	{
		$req = HTTP::Request->new(POST => $Jira::api.'search');
		$req->content_type('application/json');
		$req->authorization_basic($Jira::user,$Jira::pass);
		$req->content(
		q({
			"jql": "project = ).$Jira::project_key.q( AND labels = 'TestRail2Jira' AND labels = 'TRTestCase'",
			"fields": ["summary", "customfield_10600"],
			"startAt": ).$i.q(
		}));
		$res = $ua->request($req);
		warn $res unless $res->is_success;
		return decode_json($res->content);
	};
	
	foreach(@{$existing_bugs->{'issues'}})
	{
		my $id = $_->{'fields'}{'customfield_10600'};
		
		for(my $i=0; $i < @bugs; $i++)
		{
			if($bugs[$i]{'fields'}{'customfield_10600'} eq $id)
			{
				splice @bugs, $i, 1;
				last;
			}
		}
	}
	
}

# print encode_json( {issueUpdates=>[@bugs[0..4]]} ), "\n\n";

eval
{
	$req = HTTP::Request->new(POST => $Jira::api.'issue/bulk');
	$req->content_type('application/json');
	$req->authorization_basic($Jira::user,$Jira::pass);
	$req->content(encode_json {issueUpdates=>[@bugs]});
	$res = $ua->request($req);
	die "adding sub-task/test cases failed" unless $res->is_success;
	return decode_json($res->content);
};

sub get_story
{
	my $sid = shift;
	my @section;
	
	do {
		unshift @section, $sections{$sid}{'name'};
		$sid = $sections{$sid}{'parent_id'};
	} while ($sid);
	return join ' / ', @section;
}

1;