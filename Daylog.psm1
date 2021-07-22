<#
    TODO
    - Have a way to get all used fields (and maybe their frequency).
    - Allow autohatting multiple hats.
#>



[string]$EDITOR = "code"
[string]$DAYLOG_FILE = "/home/soren/.daylog"
[float]$ROUNDING_ERROR_TOLERANCE = 0.02
[timespan]$DATE_ORDERING_TOLERANCE = [timespan]::new(0, 0, 15, 0)
[float]$LONGEST_EXPECTED_PERIOD_HOURS = 8.5


function Convert-HoursMinutesToDecimal
{
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$Hours,

        [Parameter(Mandatory)]
        [ValidateRange(0, 59)]
        [int]$Minutes
    )

    return [decimal]([math]::Round($Hours + $Minutes / 60, 2))
}


function Get-Timestamp
{
    return (Get-Date).ToString("yyyy-MM-dd HH:mm")
}


function Format-Accumulated ([System.Collections.Generic.List[string]]$acc)
{
    return [string]::Join("`r`n", $acc)
}


function Get-DayLengthForLine
{
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Index,

        [PSCustomObject[]]$DayLengths = (Find-DaylogDirectives -DirectiveType Daylength)
    )

    $lastLength = $null
    foreach ($length in $DayLengths) {
        if ($length.LineNumber -gt $Index) {
            return $lastLength.Time
        } else {
            $lastLength = $length
        }
    }
    return $lastLength.Time
}


function parseDaylog
{
    $daylogLines = (Get-Content $DAYLOG_FILE)

    $itemStartLine = -1
    $lastObj = $null
    $accumulator = [System.Collections.Generic.List[string]]@()
    $accumulatedProperties = @{}
    $itemDate = $null
    $itemName = $null
    $itemBilling = @{}
    $tags = [System.Collections.ArrayList]@()
    $lastPunchTime = $null
    $autotagMap = @{}

    $on = 'none'
    $index = 1
    foreach ($line in $daylogLines) {
        if ($on -ne 'none') {
            $accumulator.Add($line) > $null
        }

        switch -Regex ($line) {
            '^#end\s+(.*)' {
                $endswhat = $_ -replace '^\#end (.*)\s*','$1'
                if ($endswhat -ne $on) {
                    throw "Syntax error on line ${index}: '$on' block ended by '$endswhat'"
                }

                # do some validation
                $totalHoursBilled = ($itemBilling.Values | Measure-Object -Sum).Sum
                if ($totalHoursBilled -gt $LONGEST_EXPECTED_PERIOD_HOURS) {
                    Write-Warning ("Item beginning on line $itemStartLine bills more than " +
                                   "$LONGEST_EXPECTED_PERIOD_HOURS hours ($totalHoursBilled). " +
                                   "Did you enter the date and time incorrectly?")
                }
                if ($itemBilling.Count -gt 1) {
                    $actualHoursElapsed = [math]::Round(($itemDate - $lastPunchTime).TotalHours, 2)
                    if ([math]::Abs($totalHoursBilled - $actualHoursElapsed) -gt $ROUNDING_ERROR_TOLERANCE) {
                        Write-Warning ("Split billing for item beginning on line ${itemStartLine} does not add up " +
                                       "to the total time elapsed since the last billable item " +
                                       "($totalHoursBilled vs $actualHoursElapsed). If you didn't intend to " +
                                       "use split billing, did you include a dollar amount without escaping " +
                                       "the dollar sign (`$`$)?")
                    }
                }

                $thisName = if ($itemName) { $itemName } else { "Line$itemStartLine" }

                $obj = [PSCustomObject]@{
                    Type = $on
                    Line = $itemStartLine
                    Name = $thisName
                    Timestamp = $itemDate
                    Billing = $itemBilling.Clone()
                    Content = (Format-Accumulated $accumulator)
                }
                if ($tags) {
                    $obj | Add-Member -MemberType NoteProperty -Name Tags -Value $tags.Clone()
                }
                foreach ($property in $accumulatedProperties.GetEnumerator()) {
                    $obj | Add-Member -MemberType NoteProperty -Name $property.Key -Value $property.Value
                }
                Write-Output $obj
                $lastObj = $obj

                $on = 'none'
                $accumulator.Clear()
                $accumulatedProperties.Clear()
                $itemBilling.Clear()
                $tags.Clear()
                $itemName = $null

                if ($Matches[1] -in 'done','punch','meeting') {
                    $lastPunchTime = $itemDate
                }
            }

            '^#(punch|todo|solution|done|notes|meeting)\s+(20[0-9]{2}-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9])' {
                if ($on -ne 'none') {
                    throw ("Syntax error on line ${index}: " +
                           "'$($Matches[1])' block opened while '$on' block was still open")
                }

                # we were in 'none', so we have to add it now
                $accumulator.Add($line) > $null
                $itemStartLine = $index
                $on = $Matches[1]
                try {
                    $itemDate = [datetime]::ParseExact(
                        $Matches[2],
                        "yyyy-MM-dd HH:mm",
                        [System.Globalization.CultureInfo]::InvariantCulture)
                } catch [System.FormatException] {
                    throw "Syntax error on line ${index}: invalid date format '$Matches[2]'."
                }

                if ($lastObj.Timestamp.Date -gt $itemDate+$DATE_ORDERING_TOLERANCE) {
                    Write-Warning ("Item beginning at line ${index} has a significantly earlier date than " +
                                   "the entry preceding it. Did you enter the wrong date or time?")
                }
            }

            '^!autotag \$([a-zA-Z0-9]+) \^([a-zA-Z0-9]+)' {
                $autotagMap[$Matches[1]] = $Matches[2]
                break
            }

            ' (?<!=)=([a-zA-Z]+[a-zA-Z0-9]*)' {
                $itemName = $Matches[1].Trim('=')
            }

            ':(?<PropertyName>[a-zA-Z0-9]+) (?:(?<PropertyValue>[@a-zA-Z0-9]+)|"(?<PropertyValue>[^"]+)")' {
                $accumulatedProperties[$Matches.PropertyName] = if (
                        $accumulatedProperties.ContainsKey($Matches.PropertyName)) {
                    @($accumulatedProperties[$Matches.PropertyName]) + @($Matches.PropertyValue)
                } else {
                    $Matches.PropertyValue
                }
            }

            '\^([a-zA-Z0-9]+)' {
                $tags.Add($Matches[1]) > $null
            }

            '^\s*(?<!\$)\$([a-zA-Z0-9]+)(~\*|\s|$)' {
                [string]$billedTo = $Matches[1]
                [timespan]$sinceLastPunch = $itemDate - $lastPunchTime
                [decimal]$hours = [math]::Round($sinceLastPunch.TotalHours, 2)
                if ($Matches[2] -eq '~*') {
                    $hoursAlreadyBilled = ($itemBilling.Values | Measure-Object -Sum).Sum
                    $hours = $hours - $hoursAlreadyBilled
                }
                $itemBilling.Add($billedTo, $hours) > $null

                if ($autotagMap.ContainsKey($Matches[1]) -and
                        -not $tags.Contains($autotagMap[$Matches[1]])) {
                    $tags.Add($autotagMap[$Matches[1]]) > $null
                }

                # If using ~*, we don't want to hit the next case as well.
                break
            }

            '^\s*(?<!\$)\$([a-zA-Z0-9]+)~(?:([0-9]+)h)?(?:([0-9]+)m)?' {
                [string]$billedTo, [int]$billedHours, [int]$billedMinutes = $Matches[1..3]
                $itemBilling.Add($billedTo, (Convert-HoursMinutesToDecimal $billedHours $billedMinutes)) > $null

                if ($autotagMap.ContainsKey($Matches[1]) -and
                        -not $tags.Contains($autotagMap[$Matches[1]])) {
                    $tags.Add($autotagMap[$Matches[1]]) > $null
                }
            }

        }
        $index++
    }
}


$script:daylogCache = @{Hash = ''; Data = $null}
function Read-Daylog
{
    $daylogHash = (Get-FileHash $DAYLOG_FILE).Hash
    if ($daylogHash -eq $script:daylogCache.Hash) {
        return $script:daylogCache.Data
    }

    $parsed = parseDaylog | Add-ResolvedMarkerFromList
    $script:daylogCache.Data = $parsed
    $script:daylogCache.Hash = $daylogHash
    return $parsed
}

function Add-ResolvedMarkerFromList ([Parameter(Mandatory, ValueFromPipeline)][PSCustomObject]$DaylogItem)
{
    begin {
        $allItems = [System.Collections.ArrayList]@()
        $resolvedNames = [System.Collections.ArrayList]@()
    }

    process {
        $allItems.Add($_) > $null
        foreach ($resolvedItem in $DaylogItem.Resolves) {
            $resolvedNames.Add($resolvedItem.Trim().Trim('@')) > $null
        }
    }

    end {
        $allItems | ForEach-Object {
            if ($_.Type -eq 'todo') {
                Add-Member `
                    -InputObject $_ `
                    -MemberType NoteProperty `
                    -Name Resolved `
                    -Value ($_.Name -in $resolvedNames)
            }
            Write-Output $_
        }
    }
}


##### USER CMDLETS #####

<#
.SYNOPSIS
    Open the daylog file in the `$EDITOR defined in Daylog.psm1.

.DESCRIPTION
    The Daylog PowerShell bindings only ever read from the daylog file, not
    write to it. In order to make entries, you need to edit the file using
    your own tools. This is an easy way to open up the daylog.

.EXAMPLE
    Edit-Daylog

    (There isn't much to this, is there?)
#>
function Edit-Daylog
{
    & $EDITOR $DAYLOG_FILE
}


<#
.SYNOPSIS
    Return information on Daylog directives matching your criteria.

.DESCRIPTION
    Read through the daylog file looking for all directives (i.e., lines
    outside of sections beginning with '!') of the specified type. Print
    objects describing them.

.PARAMETER DirectiveType
    Find only a specific type of directive.
#>
function Find-DaylogDirectives
{
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Autotag', 'Daylength')]
        [string]$DirectiveType
    )

    $directives = @{
        Autotag   = @{Regex = '!autotag \$([a-zA-Z0-9]+) \^([a-zA-Z0-9]+)'
                      Generator = {
                        param($LineNumber)
                        [PSCustomObject]@{
                            DirectiveType = 'Autotag'
                            LineNumber = $LineNumber
                            BillingArea = $Matches[1]
                            Tag = $Matches[2]
                        }
                      }}
        Daylength = @{Regex = '^!daylength\s+(?:(?<Hours>[0-9]+)h)?(?:(?<Minutes>[0-9]+)m)?\s*$'
                      Generator = {
                        param($LineNumber)
                        [PSCustomObject]@{
                            DirectiveType = 'Daylength'
                            LineNumber = $LineNumber
                            Time = (Convert-HoursMinutesToDecimal $Matches.Hours $Matches.Minutes)
                        }
                      }}
    }

    if (-not $directives.ContainsKey($DirectiveType)) {
        throw "Implementation missing for directive type '$DirectiveType'!"
    }

    # doing Select-String and then using the regex again to populate $Matches is *much* faster than using Where-Object
    Get-Content $DAYLOG_FILE |
        Select-String $directives[$DirectiveType].Regex |
        Select-Object Line, LineNumber |
        Foreach-Object {
            $_.Line -match $directives[$DirectiveType].Regex > $null
            Write-Output (& $directives[$DirectiveType].Generator $_.LineNumber)
    }
}


<#
.SYNOPSIS
    Return objects for Daylog entries matching your criteria.

.DESCRIPTION
    Parse the daylog file, read entries, and then return all or a subset of
    them. By default all entries are returned as PowerShell objects; this
    behavior can be modified by one or more of the many parameters. If multiple
    search criteria are given, they are ANDed together (i.e., you receive back
    only items that match all of the criteria).

.PARAMETER Type
    Find only a specific type of daylog entry (punch, todo, done, solution,
    or notes).

.PARAMETER Contains
    Search for a substring and return only entries which match. The search
    works anywhere: in text, attributes, dates, etc.

.PARAMETER Match
    Like -Contains, but uses regular expressions rather than a substring match.

.PARAMETER Attribute
    Return only entries which have a given :colonattribute set to a specific
    value; to find entries containing ':regarding StackOverflow', use
    '-Attribute regarding=StackOverflow'.

.PARAMETER MinDate
    Return only entries dated after the specified .NET datetime.

.PARAMETER MaxDate
    Return only entries dated before the specified .NET datetime. Note that
    if you specify a date only, the range is effectively exclusive since it
    matches only midnight. In other words, "2018-12-15" will include all
    entries on the 14th and entries dated exactly midnight on the 15th.

.PARAMETER Today
    Shorthand for '-MinDate [datetime]::Today'.

.PARAMETER ThisWeek
    Limit results to entries dated after midnight of the preceding Sunday (or
    midnight today, if today is Sunday).

.PARAMETER ThisFortnight
    Like -ThisWeek, but go back an additional week.

.PARAMETER ThisQuarter
    Limit results to entries from sometime in the current standard quarter
    (Jan-Mar, Apr-Jun, Jul-Sep, Oct-Dec). Unlike -ThisWeek and
    -ThisFortnight, this is not a rolling window; on April 1 for instance,
    only the current day's entries are displayed.

.PARAMETER ThisYear
    Find all entries occurring this year.

.PARAMETER ExcludeToday
    If entries from today would have been included in the results, don't show
    them. This can be helpful when reviewing margin: since the margin
    calculation considers any hours not worked *yet* today as hours not
    worked for the day in total, the calculation is otherwise fairly useless
    when in the middle of the day.

.PARAMETER BilledTo
    Return only entries billed to the specified account;
    '-BilledTo TeamSupport' finds entries that contain '$TeamSupport'.

.PARAMETER Content
    Rather than returning PowerShell objects, return only the 'Content' fields
    thereof with two newlines in between each entry. This is equivalent to
    '(Find-Daylog).Content' or 'Find-Daylog | Select-Object -ExpandProperty Content'
    except that an extra newline is inserted between objects.

.PARAMETER Unresolved
    Return only todo entries that have not been referenced in a :resolves
    attribute by another entry. This implies '-Type Todo'; specifying another
    value will yield no results.

.PARAMETER Name
    Return the item with exactly the specified name.
#>
function Find-Daylog
{
    [CmdletBinding()]
    param(
        [ValidateSet('Punch','Todo','Done','Solution','Notes','Meeting')]
        [string]$Type = $null,

        [string]$Contains = $null,

        [string]$Match = $null,

        [ValidatePattern('^[^=]+=[^=]+$')]
        [string]$Attribute = $null,

        [System.Nullable[datetime]]$MinDate = $null,

        [System.Nullable[datetime]]$MaxDate = $null,

        [switch]$Today = $false,

        [switch]$Yesterday = $false,

        [switch]$ThisWeek = $false,

        [switch]$ThisFortnight = $false,

        [switch]$ThisQuarter = $false,

        [switch]$ThisYear = $false,

        [switch]$ExcludeToday = $false,

        [string]$BilledTo = $null,

        [switch]$Content = $false,

        [switch]$Unresolved = $false,

        [string]$Name = $null,

        [string]$Tag = $null
    )

    # Some parameters are aliases for other more complicated ones. Convert them
    # to the simple versions.
    if ($Today) {
        $MinDate = [datetime]::Today
    }

    if ($Yesterday) {
        $MinDate = [datetime]::Today.Subtract([timespan]::FromDays(1))
        $MaxDate = [datetime]::Today
    }

    if ($ThisWeek -or $ThisFortnight) {
        # DayOfWeek starts with Sunday at 0. So this is equivalent to the
        # number of days since the last (or current) Sunday.
        [int]$daysSinceSunday = [datetime]::Today.DayOfWeek
        if ($ThisFortnight) {
            $daysSinceSunday += 7
        }
        $MinDate = [datetime]::Today.Subtract([timespan]::FromDays($daysSinceSunday))
    }

    if ($ThisQuarter) {
        $now = [datetime]::Today
        $MinDate, $MaxDate = switch ($now.Month) {
            {$_ -in 1..3}   { [datetime]::new($now.Year, 1, 1), [datetime]::new($now.Year, 4, 1) }
            {$_ -in 4..6}   { [datetime]::new($now.Year, 4, 1), [datetime]::new($now.Year, 7, 1) }
            {$_ -in 7..9}   { [datetime]::new($now.Year, 7, 1), [datetime]::new($now.Year, 9, 1) }
            {$_ -in 10..12} { [datetime]::new($now.Year, 9, 1), [datetime]::new($now.Year+1, 1, 1) }
        }
    }

    if ($ThisYear) {
        $MinDate = [datetime]::new(([datetime]::Today).Year, 1, 1)
    }

    if ($ExcludeToday) {
        $lastAllowableMaxDate = [datetime]::Today
        if ($null -eq $MaxDate -or $lastAllowableMaxDate -lt $MaxDate) {
            $MaxDate = $lastAllowableMaxDate
        }
    }

    # Create objects from the file and filter based on parameters.
    $objs = Read-Daylog

    if ($Type) {
        $objs = $objs | Where-Object Type -eq $Type
    }
    if ($Contains) {
        $objs = $objs | Where-Object Content -match ([regex]::Escape($Contains))
    }
    if ($Match) {
        $objs = $objs | Where-Object Content -match $Match
    }
    if ($Attribute) {
        $field, $value = $Attribute.Split('=')
        $objs = $objs | Where-Object $field -match $value
    }
    if ($MinDate) {
        $objs = $objs | Where-Object Timestamp -ge $MinDate
    }
    if ($MaxDate) {
        $objs = $objs | Where-Object Timestamp -le $MaxDate
    }
    if ($BilledTo) {
        $objs = $objs | Where-Object { $_.Billing.ContainsKey($BilledTo) }
    }
    if ($Unresolved) {
        $objs = $objs | Where-Object { $_.Type -eq 'todo' -and $_.Resolved -eq $false }
    }
    if ($Name) {
        $objs = $objs | Where-Object Name -eq $Name
    }
    if ($Tag) {
        $objs = $objs | Where-Object Tags -contains $Tag
    }

    # Output the results.
    if ($Content) {
        return [string]::Join("`r`n`r`n", $objs.Content)
    } else {
        return $objs
    }
}


<#
.SYNOPSIS
    Show an exact list of timecard punches made creating billable hours.

.DESCRIPTION
    Given a list of items obtained from Find-Daylog, walk through them
    and format each item that is either of type punch or had a nonzero
    number of hours billed to a billing area.

    Display the item type, time, billed categories, and number of hours.

    Typically this is useful for checking to make sure your billing was done
    correctly when it seems odd, or what times you were working on certain
    topics.

.PARAMETER ValueToFormat
    A stream of daylog entries.

.PARAMETER NoTotal
    Do not include the total information at the end. This may be helpful if
    you're trying to do math on or take further scripted action on the
    results.

.EXAMPLE
    See a record of what you billed today:
    PS> Find-Daylog -Today | Format-DaylogTimecard

    See how long on average you spend on Done items that mention Git and are
    billed to TeamSupport:
    PS> Find-Daylog -Type Done -Contains 'Git' -BilledTo TeamSupport |
            Format-DaylogTimecard -NoTotal |
            Measure-Object -Property Time -Average
#>
function Format-DaylogTimecard
{
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$ValueToFormat,

        [switch]$NoTotal = $false
    )

    begin {
        $accumulator = [System.Collections.ArrayList]@()
    }
    process {
        $accumulator.Add($ValueToFormat) > $null
    }

    end {
        $timecard = $accumulator | Select-Object @(
            'Type',
            'Timestamp',
            @{Name = 'BilledCategories'; Expression = { ($_.Billing.Keys) }}
            @{Name = 'Time'; Expression = {
                if ($_.Time) { $_.Time } else { ($_.Billing.Values | Measure-Object -Sum).Sum }
            }}
        ) | Where-Object { $_.Type -eq 'punch' -or $_.Time -gt 0 }

        Write-Output $timecard
        if (-not $NoTotal) {
            $totalHours = ($timecard | Measure-Object -Property Time -Sum | Select-Object -ExpandProperty Sum)
            Write-Output ([PSCustomObject]@{Type = 'total'; Time = $totalHours})
        }
    }
}


<#
.SYNOPSIS
    Group piped daylog items by billing area and show the hours spent in each.

.DESCRIPTION
    Given a list of items obtained from Find-Daylog, walk through them and sum
    up the time that you spent on each billing item. This is useful both for
    official time reporting and to get an idea of how long you're spending on
    things; the Time Reporting Reports are helpful but this has the potential
    to be even more helpful.

    Since you can pipe in absolutely any set of arguments, you can easily get
    a report on whatever you can dream of.

.PARAMETER EntriesToSearch
    A stream of daylog entries.

.PARAMETER NoTotal
    Do not include the "Total" item at the end. This may be helpful if you're
    trying to do math on or take further scripted action on the results. This
    is essentially equivalent to passing the output through
    'Where-Object { $_.BillingArea -ne 'Total' }'.

.PARAMETER Margin
    In addition to the total, show the total nominal work hours in this
    period and the difference between your worked hours and the nominal
    hours. Use !daylength directives in your daylog to indicate your nominal
    hours (a directive applies to all future entries until overridden).

    Note that this option is not meaningful if you filter your daylog entries
    by a non-time dimension -- it will almost certainly show you have a huge
    negative margin since it counts all the time you weren't working on the
    specific thing you searched for as time scheduled but not worked.

.EXAMPLE
    Show the time you've spent on each billing area since the beginning of the
    daylog:
    PS> Find-Daylog | Format-DaylogTimeSummary

.EXAMPLE
    Get time reporting data after making your last report on Friday afternoon:
    PS> Find-Daylog -ThisWeek | Format-DaylogTimeSummary

.EXAMPLE
    See how long you've spent in TFS standup meetings since the beginning of the year:
    PS> Find-Daylog `
            -Type Meeting `
            -Attribute recurrenceof=TfsStandup `
            -MinDate ([datetime]::new(2018,1,1)) | Format-DaylogTimeSummary
#>
function Format-DaylogTimeSummary
{
    param(
        [Parameter(ValueFromPipeline)]
        [PSCustomObject[]]$EntriesToSearch = (Find-Daylog),

        [switch]$NoTotal = $false,

        [switch]$Margin = $false
    )

    begin {
        $times = @{}
        $DayLengths = (Find-DaylogDirectives -DirectiveType Daylength)
        [decimal]$daylength = 0
        $seenDays = [System.Collections.Generic.HashSet[datetime]]::new()
    }

    process {
        foreach ($entry in $EntriesToSearch) {
            foreach ($pair in $entry.Billing.GetEnumerator()) {
                $category, $hours = $pair.Name, $pair.Value
                $currentValue = if ($times.ContainsKey($category)) {
                    $times[$category]
                } else {
                    0
                }
                $times[$category] = $currentValue + $hours
            }
            if (-not $seenDays.Contains($entry.Timestamp.Date)) {
                $daylength += Get-DayLengthForLine -Index $entry.Line -DayLengths $DayLengths
                $seenDays.Add($entry.Timestamp.Date) > $null
            }
        }
    }

    end {
        function constructTimeSummaryEntry ([string]$BillingArea, [decimal]$Hours) {
            return ([PSCustomObject]@{
                PSTypeName = 'TimeSummaryEntry'
                BillingArea = $BillingArea
                Hours = $Hours
            })
        }

        $times.GetEnumerator() | Foreach-Object {
            Write-Output (constructTimeSummaryEntry -BillingArea $_.Key -Hours $_.Value)
        }

        $hoursWorked = ($times.Values | Measure-Object -Sum).Sum
        if (-not $NoTotal) {
            Write-Output (constructTimeSummaryEntry -BillingArea 'Total' -Hours $hoursWorked)
        }
        if ($Margin) {
            Write-Output (constructTimeSummaryEntry -BillingArea 'NominalWorkHours' -Hours $daylength)
            Write-Output (constructTimeSummaryEntry -BillingArea 'Margin' -Hours ($hoursWorked - $daylength))
        }
    }
}


Set-Alias -Name fdl -Value Find-Daylog
Set-Alias -Name edl -Value Edit-Daylog
Set-Alias -Name fds -Value Format-DaylogTimeSummary
Set-Alias -Name fdt -Value Format-DaylogTimecard
Set-Alias -Name fdd -Value Find-DaylogDirectives
