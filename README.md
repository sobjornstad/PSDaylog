# Daylog

**Daylog** is a simple but powerful work-journaling tool and time-tracker.
You keep a running log of your day in an easy-to-use, easy-to-understand text file.
When you have a question about your work or hours too complicated to answer
by searching in the text file,
you use Daylog to parse the text file and generate PowerShell objects,
which you can then filter, group, sort, and summarize
using PowerShell's built-in cmdlets and a couple of utility cmdlets provided by Daylog.
If you already use PowerShell, you can learn to use Daylog in a few minutes.
(If you don't, PowerShell is easy and worth learning!)

Daylog has support for several common types of metadata built in,
and you can add your own fields if you want them.


## File format

A daylog file consists of **entries** and **directives**.

### Entries

There are six types of entries.

* **punch**:
  Use this entry to "punch the time clock" when you start a period of work,
  or if you want to bill time without describing what you did during it
  (perhaps because you'll explain it later).
  This is a billable item
  (this will make sense when you get to the *Billing* section).
* **done**:
  Describe what you did for a period of time.
  This is a billable item.
* **meeting**:
  Take your meeting notes under this entry,
  and bill the time to an appropriate project or area
  so you have data to back up your case
  that you're going to too many pointless meetings!
  This is a billable item.
* **solution**:
  You can build a simple knowledge base with *solution* entries.
  There are better tools for organizing knowledge like this,
  but sometimes ease of capture is paramount,
  and when that happens, solution entries are here for you.
  (Thanks to the power of PowerShell,
  you can later export these to a different tool if you wish,
  or add metadata to indicate the status of each item.)
  This is a non-billable item.
* **todo**:
  When you have your head down in some work
  and need to quickly capture a simple to-do item without breaking your focus,
  you can add a to-do entry directly to your log.
  You can later *resolve* the to-do when you have time
  to complete it or move it to a more robust task-management system,
  and there is a built-in option to find all currently unresolved todos.
  This is a non-billable item.
* **notes**:
  A catch-all category for arbitrary content.
  You know the stuff you can never find a place for anywhere else:
  passwords or confirmation codes you only need temporarily,
  snarky comments about your coworkers,
  boilerplate you want to save for later.
  This is a non-billable item.

All entry types have the same format in your daylog.
An entry begins with an opening line, which looks like this:

```
#entrytype 2020-01-01 08:00
```

The year, month, day, hours, and minutes should of course be set
to the current time when you create an entry.
Most good text editors can insert this for you automatically via a snippet or macro.

Next comes the text of your entry.
Many people like to indent some number of spaces
between the opening and closing lines,
but this is not required by Daylog.

Last comes the closing line, which begins with `#end` followed by the entry type:

```
#end entrytype
```

The # must always be the very first character on the line, with no whitespace before it.

You must end an entry before opening a new one,
and the entry type must match that of the opening line that came before it.
If it doesn't,
you'll receive a syntax error indicating the line exhibiting the problem
when you try to parse the daylog.
This catches a significant number of common errors.

Putting it all together, here's a simple *done entry*:

```
#done 2021-07-21 17:55
    Finished writing my TPS reports.
#end done
```

Entries are expected to be found in the file in chronological order,
and you'll receive a warning if they don't,
as this usually means you've made a typo in the date or time.
To avoid being annoying if you add two entries right next to each other
and later increase the time on the first one
to account for the time you spent writing the entry,
Daylog has a small tolerance inside of which it won't warn
(by default 15 minutes).


### Entry metadata

Entries aren't too interesting by themselves:
so far, they don't let us do anything we couldn't do
with a free-form text file.
Daylog starts to shine when we add metadata to each entry.

Metadata items are introduced by a symbol,
different for each type of metadata.
In most cases, it's easiest to write each piece of metadata on a separate line at the top of the entry;
however, Daylog will recognize tags and attributes elsewhere within an entry,
including in the middle of a line,
so if you can integrate them directly into your text, feel free.

#### Billing

Time-tracking information is obtained from the *billing* of each entry.
Billing is assigned with the `$` symbol plus an account name.
Billing account names may contain letters and numbers;
the first space or character of punctuation ends the account name.
Billing accounts, like all metadata, are created on the fly when you use them for the first time.

For each entry, you can use either *standard billing* or *split billing*.

**Standard billing** consists of just the dollar sign plus an account or project name,
like `$TPSReports` or `$BobsWebsite`.
An standard billing item bills all of the time elapsed
since the preceding *billable entry* (*punch*, *done*, or *meeting*)
to the specified account.

**Split billing** allows you to bill time within a single entry to multiple accounts.
This is useful if you forget to check in for a while
or get repeatedly interrupted or distracted
and work on several different tasks during a period of time.
Split billing adds a tilde and the amount of time in hours and minutes
after each billing item:

```
#done 2021-05-23 09:00
    $BobsWebsite~1h10m
    $TPSReports~20m

    Worked on fixing the mobile CSS for Bob's website.
    Interrupted briefly to go file my TPS reports.
#end done
```

The total amount of time in all the split-billing items
should add up to the amount of time since the last billable entry;
if it doesn't, you'll get a warning.
You'll also get a warning
if you bill an unreasonable number of hours in a single entry
(eight and a half hours by default).

If you wish,
you can write `*` instead of an amount of time on the final billing item;
this will consume all time since the last billable entry
that isn't accounted for by another split billing item on this entry.
(Beware that the asterisk can mask typos and arithmetic errors
which would otherwise be caught by Daylog noticing
that your split billing times don't add up
to the total time since the last billable entry.
It's a good idea to double-check your work when using an asterisk billing item.)

If including actual monetary amounts within the text of an entry,
double up the dollar sign to tell Daylog it's not a billing item.
So an amount of five hundred dollars would be written `$$500.00`.

#### Tags

Tags categorize your work and group projects and entries together
so you can quickly limit your searches to a single responsibility or problem domain.
For instance, you might have a "teaching" tag and a "consulting" tag,
or a "web design" tag, an "education" tag, and an "administration" tag.

Tags use the character `^` (looks like a hat) plus the tag name.
tag names may contain letters and numbers;
the first space or character of punctuation ends the tag name.

Unlike billing accounts, tags are not mutually exclusive,
and you can add any number of tags to an entry.

If you always assign a particular tag to entries with a particular billing item,
you can use an `!autotag` directive to reduce the amount of typing required
and the risk of skewing your data by forgetting to add the tag to an entry.

#### Item names

An entry can be given a name using `=` plus the name.
Item names may contain letters and numbers;
the first space or character of punctuation ends the item name.

You can use the reference name to find the entry quickly
or to mention it in another entry.
The todo-resolution mechanism uses reference names
to indicate when the todo is resolved.

#### Properties

Arbitrary name-value metadata can be added to entries using *properties*.
Property names may contain letters and numbers;
the first space or character of punctuation ends the property name.
Property values may be specified in one of two formats:
ending at the first non-alphanumeric character like the property name,
or beginning with a double quotation mark `"`
and ending at the next double quotation mark
(the quotation marks are omitted from the value).

Daylog properties on an entry
become properties on the PowerShell object when parsed,
so the following property names are reserved and may not be used:
`Type`, `Line`, `Name`, `Timestamp`, `Billing`, `Content`,
`Equals`, `GetHashCode`, `GetType`, and `ToString`.
Remember that PowerShell property names are case-insensitive,
so, e.g., `type` won't work either.

The only property understood by Daylog itself is `:resolves`,
which is used to resolve to-do items.
Otherwise, what you do with properties is up to you.
They can be used to implement almost any workflow.


### Directives

Directives begin with `!` and perform some kind of configuration;
they remain in effect until and unless overridden by another directive later in the file.

* `!autotag $BillingAccount ^Tag`:
  Automatically add the tag *Tag* to any entry with a billing account of
  $BillingAccount.
* `!daylength 8h30m`:
  When performing margin calculations,
  this is the target number of hours you would like to work per day.


## Cmdlets

Once you have written a Daylog file,
you can use several PowerShell cmdlets provided by Daylog
to work with the data.

### `Find-Daylog`

This cmdlet (alias `fdl`) parses your daylog
and produces a stream of PowerShell objects, one for each matching entry.
With no parameters, it returns all entries in the log.
It supports several dozen parameters
which can be used to conveniently limit the results;
if you give several, only entries that match all of the criteria are returned.
Of course, if you need something more complicated,
you can use PowerShell's filtering tools!

Use `Get-Help Find-Daylog` for a full description of all the supported parameters.

### `Format-DaylogTimecard`

This cmdlet (alias `fdt`) accepts the output of `Find-Daylog` as pipeline input
and creates a table showing the type, timestamp, billing accounts, and time billed
for each entry.
This is a convenient way to review your day or week
or to find a mistake in your time reporting.

By default, the last line will show the total time;
use the `-NoTotal` parameter
to omit this line and avoid doubling the observed amount of time spent
if passing off the results to another cmdlet or program
or doing arithmetic on them.

### `Format-DaylogTimeSummary`

This cmdlet (alias `fds`) accepts the output of `Find-Daylog` as pipeline input
and produces the total number of hours spent in each billing area.
In order to produce cross-cutting reports,
you use parameters of `Find-Daylog` or PowerShell filtering tools
to limit the input.
For instance, to see a breakdown of time by billing area
for all meetings with the `Consulting` tag,
you could use `Find-Daylog -Tag Consulting -Type Meeting | Format-DaylogTimeSummary`.

By default, the last line will show the total time;
use the `-NoTotal` parameter
to omit this line and avoid doubling the observed amount of time spent
if passing off the results to another cmdlet or program
or doing arithmetic on them.

#### Margin calculation

`Format-DaylogTimeSummary` can do *margin calculation* on your work hours
with the `-Margin` switch.
This is handy if you're trying to work a certain number of hours over a period of time,
but don't care exactly how many hours you work per day.

The `!daylength` directive sets how many hours you want to work per day.
`Format-DaylogTimeSummary`
will then check how many unique days have entries in its pipeline input
and multiply the day length by this figure to give your *nominal work hours*,
or the target number of hours to work over the period.
The total number of billed hours minus the nominal work hours is the current margin;
it's negative if you need to work additional hours to reach your target
and positive if you are currently over your target.

If you worked 0 hours on a day but want it included in your margin calculation
(for instance, you want to work 40 hours over a 5-day week,
and you took Thursday off and want to make up the time over the rest of the week),
you can insert a dummy pair of punch entries with no time between them,
creating a 0-hour bill to the specified account on that day
and causing the day to be counted as a work day:

```
#punch 2021-07-20 00:00
    Didn't work today.
#end punch

#punch 2021-07-20 00:00
    $EmptyDay
#end punch
```

More powerful options for margin calculation are planned.
