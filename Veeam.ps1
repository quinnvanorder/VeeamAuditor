# Quinn Van Order 2019
#Early version of code, requires significant cleanup. This is meant to act as a proof of concept for now.

#Arguments

[int]$Global:AuditHours = $args[0]
IF(!($Global:AuditHours)){$Global:AuditHours = 24} #Defaults to 24 hours

$Global:ReportSelection = $args[1]

#Variables
$Global:Data =@()
$Global:CountErrors = 0
$Global:LicenseExpiration = ''
$Global:Version = ''
$Global:Log = ''
$Global:Status = ''
$Global:TotalEnabled = ''
$Global:TotalDisabled = ''
$Global:TotalFailed = ''
$Global:TotalNotFailed = ''
$Global:OldestSuccess = ''
$Global:DaysSinceOldestSuccess = ''
$Global:TotalErrors = ''
$Global:TotalWarnings = ''

If(test-path 'C:\temp\VeeamAudit.csv'){Remove-Item 'C:\temp\VeeamAudit.csv' -Force} #Clean up line for multiple test re-runs. Verifies the output txt file is destroyed prior to run to prevent improper appending. 
If(test-path 'C:\temp\VeeamAudit.txt'){Remove-Item 'C:\temp\VeeamAudit.txt' -Force} #Clean up line for multiple test re-runs. Verifies the output txt file is destroyed prior to run to prevent improper appending. 
    
#Functions
Function GenerateOutput #Immediatly terminates script if service or snapin is missing. Later turned this into the general status output, may want to rename to be more clear. 
{
    Write-Host $Global:Status
    $Global:Status | Out-File C:\temp\VeeamAudit.txt
    Exit
}

Function ServiceCheck #Verifies that the primary backup service is present. If not, device may not be a BDR, but instead could be a repository which wouldnt have jobs. If primary service is present, verifies all Veeam services are started prior to moving on
{
    $Services = get-service -displayname "Veeam Backup Service" -ErrorAction SilentlyContinue
    IF (($Services))
    {
        get-service -displayname 'veeam*' | Where {$_.StartType -eq 'Automatic'} | foreach-object { Start-Service -InputObj $_.Name }
    }
    ELSE
    {
        $Global:Status = 'ERROR: Veeam Backup Service Not Present.'
        GenerateOutput
    }
}

Function LoadSnapIn #Loads Powershell snapin, reports on failure
{
    Add-PSSnapin VeeamPSSnapin -ErrorVariable SnapIn -ErrorAction SilentlyContinue
    IF (($SnapIn))
    {
        $Global:Status = 'ERROR: Veeam PowerShell SnapIn Not Loaded.'
        GenerateOutput
    }
}

Function GetVersion
{
    $Global:Version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo('C:\Program Files\Veeam\Backup and Replication\Console\veeam.backup.shell.exe').FileVersion
    IF (!(([Version] $Global:Version) -ge ([Version] "9.5.4")))
    {
        $Global:Status = 'ERROR: Veeam Older Than 9.5 U4a. Upgrade Required.'
        GenerateOutput
        
    }
}

Function WarnLowDisk
{
    $DiskSpace = ''
    $colDisks = get-wmiobject Win32_LogicalDisk -Filter 'DriveType = 3'
    foreach ($disk in $colDisks) 
    {
        if ($disk.size -gt 0)
        {
            $PercentFree = [Math]::round((($disk.freespace/$disk.size) * 100))
        } 
        else 
        {
            $PercentFree = 0
        }
        $Drive = $disk.DeviceID
        IF ($PercentFree -lt 5)
        {
        $DiskSpace += $Drive + $PercentFree + ","
        }
    

    }
    IF ($DiskSpace) 
    {
        $Global:Status = 'ERROR: Disk Below 5% Free'
        GenerateOutput
    }
}

Function GatherData #Populates the 3 data arrays so they can be queried locally for efficiency  
{
	$Global:VBREPJob = Get-VBREPJob
	$Global:VBRJob = Get-VBRJob
	$Global:VBRBackupSession = Get-VBRBackupSession
    $Global:VBREPSession = Get-VBREPSession 
    $Global:VBRBackup = Get-VBRBackup
}

Function PopulateBackups
{
    FOREACH ($Job in ($Global:VBRJob | Where {$_.JobType -eq 'Backup'})) #Loops through all backup jobs
    {
        #Variables
        $jobBackupSize = 0
	    $jobDataSize = 0
        $IntervalSuccess = 0
        $IntervalWarning = 0
        $IntervalFailure = 0
        $Status = ''
        $NextRun = ''
        $Mode = ''
        $Additions = ''
        $Subtractions = ''
        $Members = ''
        
        #Determines schedule type of job
        IF ($Job.ScheduleOptions.OptionsDaily.Enabled -eq 'True')
        {
            $Interval = $Job.ScheduleOptions.OptionsDaily.Kind
        }
        ELSEIF ($Job.ScheduleOptions.OptionsMonthly.Enabled -eq 'True')
        {
            $Interval = $Job.ScheduleOptions.OptionsMonthly.Kind
        }
        ELSEIF ($Job.ScheduleOptions.OptionsPeriodically.Enabled -eq 'True')
        {
            $Interval = $Job.ScheduleOptions.OptionsPeriodically.Kind
        }

        #Query Latest Run Time
        $Latest = $Job.ScheduleOptions.LatestRunLocal
        
        
        #Query schedule, next run time, and if job is an offsite, the repository offsites are pointed at
        
        IF ($Job.ScheduleOptions.OptionsScheduleAfterJob.IsEnabled -eq $True) #Clause to occur if job is scheduled to run after a seperate job
        {
            $Interval = "Chained" #Note that this overwrites any settings to interval above. If job is chained, any data present within the scheduleoptions will be invalid
            $NextRun = "After " + ($Global:VBRJob | Where {$_.id -eq $Job.PreviousJobIdInScheduleChain}).name
        }
        ELSEIF (!($Job.ScheduleOptions.NextRun)) #Clause to occur if job is not scheduled to run
        {
            $NextRun = "NOT SCHEDULED"
        }
        ELSE #Clause to run in all "normal" situations where jobs have a direct schedule
        {
            $NextRun = $Job.ScheduleOptions.NextRun
        }

        #VBRBackup Loop; used to eunuerate job storage size
        $Backups = $Global:VBRBackup | where {$_.JobId -eq $Job.Id}
        FOREACH ($Backup in $Backups) #Totals size by adding up all backup entries to total per job. 
        {
            #Get Data Size
            $jobBackupSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.BackupSize | Measure-Object -Sum).Sum/1GB,1)}} ).Size
            $jobDataSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.DataSize | Measure-Object -Sum).Sum/1GB,1)}}).Size
            #OIB is "Object In Backup", enunerates each one to find member names, disk configuration and the like
            $Machines = ($Backup.GetLastOibs()).AuxData
            FOREACH ($Machine in $Machines)
            {
                $Exclude = ''
                $Excluded = ''
                $Exclude = $Machine.ExcludedSrcDisks.Port
                IF ($Exclude)
                {
                    $Subtractions += " | " + $Machine.VmName + ": "
                }
                $TempDisk = ''
                FOREACH ($Disk in $Exclude) 
                {
                    [String]$Excluded = [String]$Disk.BusType + [String]$Disk.Channel + "-" + [String]$Disk.Port
                    $TempDisk += $Excluded + ", "
                }
                
                IF ($TempDisk) 
                {
                    $TempDisk = $TempDisk.Substring(0, $TempDisk.Length - 2)
                }  
                $Subtractions += $TempDisk
                
                $Members += $Machine.VmName + ", "
                
                IF ($Mode -eq "Volumes")
                {
                    IF ($Exclude)
                    {
                        #$Subtractions += $Machine.VmName + ": " + $Exclude + " | "
                        $Additions += $Machine.VmName + ": " + ([system.String]::Join(", ", ($Machine.DisksInfos.TargetInsideFolderPath))) + " | "
                    }
                    ELSE
                    {
                        $Additions += $Machine.VmName + ": " + "Everything | "
                    }
                }
                ELSE
                {
                    IF ($Exclude)
                    {
                        $Mode = "Volumes"
                        $Additions += $Machine.VmName + ": " + ([system.String]::Join(", ", ($Machine.DisksInfos.TargetInsideFolderPath))) + " | "
                    }
                    ELSE
                    {
                        $Mode = "Everything "
                        $Additions += $Machine.VmName + ": " + "Everything | "
                    }
                } 
            }  
            #Clean up trailing strings
            IF ($Members) 
            {
                $Members = $Members.Substring(0, $Members.Length - 2)
            }  
            IF ($Additions) 
            {
                $Additions = $Additions.Substring(0, $Additions.Length - 2)
            }
            IF ($Subtractions) 
            {
                $Subtractions = $Subtractions.Substring(3, $Subtractions.Length - 3) 
            }
        }
        
        #Get last status and status over target interval time
        IF ($Job.GetLastResult() -ne "None") #Currently running jobs return a status of None. If latest job entry is running, check status of latest minus 1
            {
                $Status = $Job.GetLastResult()
            }
            ELSE 
            {
                $Status = ($Global:VBRBackupSession | Where {$_.jobId -eq $Job.Id.Guid} | Sort EndTimeUTC -Descending)[1].Result 
            }
        
        $Sessions = ($Global:VBRBackupSession | Where {$_.jobId -eq $Job.Id.Guid} | Where {$_.EndTime -ge (Get-Date).addhours(-$Global:AuditHours)})
        FOREACH ($Run in $Sessions) #Counters for each type of status within target timeframe
        {
            IF ($Run.Result -eq 'Failed')
            {
                $IntervalFailure++
            }
            ELSEIF ($Run.Result -eq 'Warning')
            {
                $IntervalWarning++
            }
            ELSEIF ($Run.Result -eq 'Success')
            {
                $IntervalSuccess++
            }                        
        }
        #Last Run Time
        $Latest = $Job.ScheduleOptions.LatestRunLocal
        
        #Is Job Enabled
        $IsEnabled = $Job.IsScheduleEnabled
        #Handling situations which results in blank fields
        IF ($IsEnabled -ne "True")
        {
            $NextRun = 'Disabled'
        }
        
        #Clears detailed data if mode is everything
        IF ($Mode -ne "Volumes")
        {
            $Additions = ''
            $Subtractions = ''
        }

        #Populates job data array with all needed values
        $Global:Data += [PSCustomObject]@{
        Name = $Job.Name
        Status = $Status
        Enabled = $IsEnabled
        Type = $Job.JobType
        Chained = $Job.ScheduleOptions.OptionsScheduleAfterJob.IsEnabled
        Schedule = $Interval
        NextRun = $NextRun
        LatestRun = $Latest
        Retention = $Job.BackupStorageOptions.RetainCycles
        BackupSize = $jobBackupSize
        DataSize = $jobDataSize
        IntervalSuccess = $IntervalSuccess
        IntervalWarning = $IntervalWarning
        IntervalFailure = $IntervalFailure
        Members = $Members
        Mode = $Mode
        Additions = $Additions
        Subtractions = $Subtractions   
        }
    } 
}

Function PopulateOffsites
{
    #VBRJob Loop; used for all types of jobs other than the "bad" agents
    FOREACH ($Job in ($Global:VBRJob | Where {$_.JobType -eq 'BackupSync'}))
    {
        #Variables
        $CloudProvider = ''
        $jobBackupSize = 0
	    $jobDataSize = 0
        $IntervalSuccess = 0
        $IntervalWarning = 0
        $IntervalFailure = 0
        $Status = ''

        #Query Latest Run Time
        $Latest = $Job.ScheduleOptions.LatestRunLocal
        
        #Query schedule, next run time, and if job is an offsite, the repository offsites are pointed at
        
        #Specifies Cloud Provider
        $BackupRepository = $Job.GetTargetRepository().name
        $CloudProvider = (Get-VBRBackupRepository -name $BackupRepository).FindHost().Name
        $Backups = $Global:VBRBackup | where {$_.JobId -eq $Job.Id}
        
        FOREACH ($Backup in $Backups) #Totals size by adding up all backup entries to total per job. 
        {
            $jobBackupSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.BackupSize | Measure-Object -Sum).Sum/1GB,1)}} ).Size
            $jobDataSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.DataSize | Measure-Object -Sum).Sum/1GB,1)}}).Size
        }
        
        #Get last status and status over target interval time
        IF ($Job.GetLastResult() -ne "None") #Currently running jobs return a status of None. If latest job entry is running, check status of latest minus 1
        {
            $Status = $Job.GetLastResult()
        }
        ELSE 
        {
            $Status = ($Global:VBRBackupSession | Where {$_.jobId -eq $Job.Id.Guid} | Sort EndTimeUTC -Descending)[0].Result 
        }
        #Assessing jobs within specified audit interval     
        $Sessions = ($Global:VBRBackupSession | Where {$_.jobId -eq $Job.Id.Guid} | Where {$_.EndTime -ge (Get-Date).addhours(-$Global:AuditHours)})
        FOREACH ($Run in $Sessions) #Counters for each type of status within target timeframe
        {
            IF ($Run.Result -eq 'Failed')
            {
                $IntervalFailure++
            }
            ELSEIF ($Run.Result -eq 'Warning')
            {
                $IntervalWarning++
            }
            ELSEIF ($Run.Result -eq 'Success')
            {
                $IntervalSuccess++
            }                        
        }
        
        #List members and linked backup of offsite job
        $Members = ''
        FOREACH ($Id in $Job.LinkedJobIds.guid)
        {
            $LinkedJob = ($Global:VBRJob | where {$_.id -eq $Id}).name

            IF (!$LinkedJob)
            {
                $LinkedJob = $Global:VBRBackup | where {$_.JobId -eq $Id}
                $Members = $LinkedJob.GetJob().GetObjectsInJob().Name
                $LinkedJob = ($LinkedJob).name
            }
            ELSE
            {
                FOREACH ($Job2 in ($Global:VBRJob | where {$_.Name -eq $LinkedJob}))
                {
                    $Objects = $Job2.GetObjectsInJob()
                    FOREACH ($Object in $Objects)
                    {
                        $Members +=  $Object.Name + ", "
                    }
                    #Cleanup trailing comma
                    IF ($Members) 
                    {
                    $Members = $Members.Substring(0, $Members.Length - 2)
                    }
                }
            } 
        }
        
        #Last Run Time
        $Latest = $Job.ScheduleOptions.LatestRunLocal
        
        #Populates job data array with all needed values
        $Global:Data += [PSCustomObject]@{
        Name = $Job.Name
        Status = $Status
        Enabled = $Job.IsScheduleEnabled
        Type = $Job.JobType
        LatestRun = $Latest
        Retention = $Job.BackupStorageOptions.RetainCycles
        BackupSize = $jobBackupSize
        DataSize = $jobDataSize
        IntervalSuccess = $IntervalSuccess
        IntervalWarning = $IntervalWarning
        IntervalFailure = $IntervalFailure
        Members = $Members
        LinkedJob = $LinkedJob
        CloudProvider = $CloudProvider
        }
    } 
}

Function PopulateAgents
{
    FOREACH ($Job in ($Global:VBRJob | Where {$_.JobType -eq 'EpAgentBackup'}))
    {
        #Variables
        $jobBackupSize = 0
	    $jobDataSize = 0
        $IntervalSuccess = 0
        $IntervalWarning = 0
        $IntervalFailure = 0
        $Status = ''
        $Members = ''
        $Additions = ''
        $BackupMode = ''
        $Subtractions = ''
        $Latest = ''
        
        #Determines schedule type of job
        IF ($Job.ScheduleOptions.OptionsDaily.Enabled -eq 'True')
        {
            $Interval = $Job.ScheduleOptions.OptionsDaily.Kind
        }
        ELSEIF ($Job.ScheduleOptions.OptionsMonthly.Enabled -eq 'True')
        {
            $Interval = $Job.ScheduleOptions.OptionsMonthly.Kind
        }
        ELSEIF ($Job.ScheduleOptions.OptionsPeriodically.Enabled -eq 'True')
        {
            $Interval = $Job.ScheduleOptions.OptionsPeriodically.Kind
        }

        
        
        #Query schedule, next run time, and if job is an offsite, the repository offsites are pointed at
        IF ($Job.ScheduleOptions.OptionsScheduleAfterJob.IsEnabled -eq $True) #Clause to occur if job is scheduled to run after a seperate job
        {
            $Interval = "Chained"
            $NextRun = "After " + ($Global:VBRJob | Where {$_.id -eq $Job.PreviousJobIdInScheduleChain}).name
        }
        ELSEIF (!($Job.ScheduleOptions.NextRun)) #Clause to occur if job is not scheduled to run
        {
            $NextRun = "NOT SCHEDULED"
        }
        ELSE #Clause to run in all "normal" situations where jobs have a direct schedule
        {
            $NextRun = $Job.ScheduleOptions.NextRun
        }

        #VBRBackup Loop; used to eunuerate job storage size
        $Backups = $Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}
        FOREACH ($Backup in $Backups) #Totals size by adding up all backup entries to total per job. 
        {
            $jobBackupSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.BackupSize | Measure-Object -Sum).Sum/1GB,1)}} ).Size
            $jobDataSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.DataSize | Measure-Object -Sum).Sum/1GB,1)}}).Size
        }
        
        #Get last status and status over target interval time
        $Sessions = [veeam.backup.core.cbackupsession]::GetByJob($Job.Id)
        $Status = ($Sessions | Sort EndTimeUTC -Descending | Select -First 1).result
        $IntervalSuccess = ($Sessions | Where {($_.EndTime -ge (Get-Date).addhours(-$Global:AuditHours)) -and ($_.Result -eq 'Success')}).count
        $IntervalWarning = ($Sessions | Where {($_.EndTime -ge (Get-Date).addhours(-$Global:AuditHours)) -and ($_.Result -eq 'Warning')}).count
        $IntervalFailure = ($Sessions | Where {($_.EndTime -ge (Get-Date).addhours(-$Global:AuditHours)) -and ($_.Result -eq 'Failed')}).count
        
        #Get Members of each Job
        $Objects = (($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs())
        FOREACH ($Object in $Objects)
        {
            #Query Latest Run Time
            $Latest = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).CreationTime.DateTime | Select -First 1)
            #Query Mode
            $BackupMode = $Object.AuxData.OriginalDiskFilter.BackupMode
            #Enumerating Volume specific job attributes
            IF ($BackupMode -eq "Volumes")
            {
                $A = (((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.Drives.ToXmlData()).root.VolumeOrPartitionId.MountPoint| Select -Unique)
                $Additions = ([system.String]::Join(", ", $A)) -replace " , "
                $OSBackup = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.BackupSystemState | Select -Unique)
                $UserBackup = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.BackupUserFolders | Select -Unique)
            }
            #Enumerating File Level Backup specific job attributes
            IF ($BackupMode -eq "Manual") #Temtative name
            {
                $A = (((((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.Drives).ToXmlData()).root.includefolders.string.value) + " " + ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.IncludeMasks)| Select -Unique)
                $Additions = ([system.String]::Join(", ", $A)) -replace " , "
                $S = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.ExcludeMasks | Select -Unique)
                $Subtractions = ([system.String]::Join(", ", $S)) -replace " , "
                $OSBackup = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.BackupSystemState | Select -Unique)
                $UserBackup = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.BackupUserFolders | Select -Unique)
            }
            $Members +=  $Object.Name + ", "
        }
        #Cleanup trailing comma
        IF ($Members) 
        {
        $Members = $Members.Substring(0, $Members.Length - 2)
        }
        
        #Handling situations which results in blank fields
        $IsEnabled = $Job.IsScheduleEnabled
        IF ($IsEnabled -ne "True")
        {
            $NextRun = 'Disabled'
        }

        #Populates job data array with all needed values
        $Global:Data += [PSCustomObject]@{
        Name = $Job.Name
        Status = $Status
        Enabled = $IsEnabled
        Type = $Job.JobType
        Chained = $Job.ScheduleOptions.OptionsScheduleAfterJob.IsEnabled
        Schedule = $Interval
        NextRun = $NextRun
        LatestRun = $Latest
        Retention = $Job.BackupStorageOptions.RetainCycles
        BackupSize = $jobBackupSize
        DataSize = $jobDataSize
        IntervalSuccess = $IntervalSuccess
        IntervalWarning = $IntervalWarning
        IntervalFailure = $IntervalFailure
        Members = $Members
        Mode = $BackupMode
        Additions = $Additions
        Subtractions = $Subtractions
        OSBackedUp = $OSBackup
        UsersBackedUp = $UserBackup
        }
    } 
}

Function PopulateAgentPolicy
{
    FOREACH ($Job in ($Global:VBRJob | Where {$_.JobType -eq 'EpAgentPolicy'}))
    {
        #Variables
        $jobBackupSize = 0
	    $jobDataSize = 0
        $IntervalSuccess = 0
        $IntervalWarning = 0
        $IntervalFailure = 0
        $Status = ''
        $Members = ''
        $Additions = ''
        $BackupMode = ''
        $Subtractions = ''
        $Latest = ''
        
        #Determines schedule type of job
        IF ($Job.ScheduleOptions.OptionsDaily.Enabled -eq 'True')
        {
            $Interval = $Job.ScheduleOptions.OptionsDaily.Kind
        }
        ELSEIF ($Job.ScheduleOptions.OptionsMonthly.Enabled -eq 'True')
        {
            $Interval = $Job.ScheduleOptions.OptionsMonthly.Kind
        }
        ELSEIF ($Job.ScheduleOptions.OptionsPeriodically.Enabled -eq 'True')
        {
            $Interval = $Job.ScheduleOptions.OptionsPeriodically.Kind
        }

        
        
        #Query schedule, next run time, and if job is an offsite, the repository offsites are pointed at
        IF ($Job.ScheduleOptions.OptionsScheduleAfterJob.IsEnabled -eq $True) #Clause to occur if job is scheduled to run after a seperate job
        {
            $Interval = "Chained"
            $NextRun = "After " + ($Global:VBRJob | Where {$_.id -eq $Job.PreviousJobIdInScheduleChain}).name
        }
        ELSEIF (!($Job.ScheduleOptions.NextRun)) #Clause to occur if job is not scheduled to run
        {
            $NextRun = "NOT SCHEDULED"
        }
        ELSE #Clause to run in all "normal" situations where jobs have a direct schedule
        {
            $NextRun = $Job.ScheduleOptions.NextRun
        }

        #VBRBackup Loop; used to eunuerate job storage size
        $Backups = $Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}
        FOREACH ($Backup in $Backups) #Totals size by adding up all backup entries to total per job. 
        {
            $jobBackupSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.BackupSize | Measure-Object -Sum).Sum/1GB,1)}} ).Size
            $jobDataSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.DataSize | Measure-Object -Sum).Sum/1GB,1)}}).Size
        }
        
        #Get last status and status over target interval time
        $Sessions = [veeam.backup.core.cbackupsession]::GetByJob($Job.Id)
        $Status = ($Sessions | Sort EndTimeUTC -Descending | Select -First 1).result
        $IntervalSuccess = ($Sessions | Where {($_.EndTime -ge (Get-Date).addhours(-$Global:AuditHours)) -and ($_.Result -eq 'Success')}).count
        $IntervalWarning = ($Sessions | Where {($_.EndTime -ge (Get-Date).addhours(-$Global:AuditHours)) -and ($_.Result -eq 'Warning')}).count
        $IntervalFailure = ($Sessions | Where {($_.EndTime -ge (Get-Date).addhours(-$Global:AuditHours)) -and ($_.Result -eq 'Failed')}).count
        
        #Get Members of each Job
        $Objects = (($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs())
        FOREACH ($Object in $Objects)
        {
            #Query Latest Run Time
            $Latest = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).CreationTime.DateTime | Select -First 1)
            #Query Mode
            $BackupMode = $Object.AuxData.OriginalDiskFilter.BackupMode
            #Enumerating Volume specific job attributes
            IF ($BackupMode -eq "Volumes")
            {
                $A = (((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.Drives.ToXmlData()).root.VolumeOrPartitionId.MountPoint| Select -Unique)
                $Additions = ([system.String]::Join(", ", $A)) -replace " , "
                $OSBackup = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.BackupSystemState | Select -Unique)
                $UserBackup = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.BackupUserFolders | Select -Unique)
            }
            #Enumerating File Level Backup specific job attributes
            IF ($BackupMode -eq "Manual") #Temtative name
            {
                $A = (((((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.Drives).ToXmlData()).root.includefolders.string.value) + " " + ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.IncludeMasks)| Select -Unique)
                IF ($A)
                {
                    $Additions = ([system.String]::Join(", ", $A)) -replace " , "
                }
                $S = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.ExcludeMasks | Select -Unique)
                IF ($S)
                {
                    $Subtractions = ([system.String]::Join(", ", $S)) -replace " , "
                }
                
                $OSBackup = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.BackupSystemState | Select -Unique)
                $UserBackup = ((($Global:VBRBackup | where {$_.BackupPolicyTag -eq $Job.Id}).GetLastOibs()).AuxData.OriginalDiskFilter.BackupUserFolders | Select -Unique)
            }
            $Members +=  $Object.Name + ", "
        }
        #Cleanup trailing comma
        IF ($Members) 
        {
        $Members = $Members.Substring(0, $Members.Length - 2)
        }
        
        #Handling situations which results in blank fields
        $IsEnabled = $Job.IsScheduleEnabled
        IF ($IsEnabled -ne "True")
        {
            $NextRun = 'Disabled'
        }

        #Populates job data array with all needed values
        $Global:Data += [PSCustomObject]@{
        Name = $Job.Name
        Status = $Status
        Enabled = $IsEnabled
        Type = $Job.JobType
        Chained = $Job.ScheduleOptions.OptionsScheduleAfterJob.IsEnabled
        Schedule = $Interval
        NextRun = $NextRun
        LatestRun = $Latest
        Retention = $Job.BackupStorageOptions.RetainCycles
        BackupSize = $jobBackupSize
        DataSize = $jobDataSize
        IntervalSuccess = $IntervalSuccess
        IntervalWarning = $IntervalWarning
        IntervalFailure = $IntervalFailure
        Members = $Members
        Mode = $BackupMode
        Additions = $Additions
        Subtractions = $Subtractions
        OSBackedUp = $OSBackup
        UsersBackedUp = $UserBackup
        }
    } 
}

Function PopulateDirectAgents
{
    FOREACH ($Job in ($Global:VBREPJob | Where {$_.Type -eq 'EndpointBackup'}))
    {
        $Backups = $Global:VBRBackup | where {$_.JobId -eq $Job.Id}
        #Schedule
        IF ($Backups.GetJob().ScheduleOptions.OptionsDaily.Enabled -eq 'True')
        {
            $Interval = $Backups.GetJob().ScheduleOptions.OptionsDaily.Kind
        }
        ELSEIF ($Backups.GetJob().ScheduleOptions.OptionsMonthly.Enabled -eq 'True')
        {
            $Interval = $Backups.GetJob().ScheduleOptions.OptionsMonthly.Kind
        }
        ELSEIF ($Backups.GetJob().ScheduleOptions.OptionsPeriodically.Enabled -eq 'True')
        {
            $Interval = $Backups.GetJob().ScheduleOptions.OptionsPeriodically.Kind
        }
        #Data Size
        $jobBackupSize = 0;
	    $jobDataSize = 0;

        #Get Members of each Job
        $Objects = $Backups.GetLastOibs()
        FOREACH ($Object in $Objects)
        {
            #Query Latest Run Time
            $Latest = $Object.CreationTime.ToString("M/d/yyyy h:mm:ss tt")
            #Query Mode
            $BackupMode = $Object.AuxData.OriginalDiskFilter.BackupMode
            #Enumerating Volume specific job attributes
            IF ($BackupMode -eq "Volumes")
            {
                IF($Object.AuxData.OriginalDiskFilter.Drives)
                {
                    $A = (($Object.AuxData.OriginalDiskFilter.Drives.ToXmlData()).root.VolumeOrPartitionId.MountPoint | Select -Unique)
                    $Additions = ([system.String]::Join(", ", $A)) -replace " , "
                }
                
                $OSBackup = ($Object.AuxData.OriginalDiskFilter.BackupSystemState | Select -Unique)
                $UserBackup = ($Object.AuxData.OriginalDiskFilter.BackupUserFolders | Select -Unique)
            }
            #Enumerating File Level Backup specific job attributes
            IF ($BackupMode -eq "Manual") #Temtative name
            {
                IF($Object.AuxData.OriginalDiskFilter.Drives)
                {
                    $A = (($Object.AuxData.OriginalDiskFilter.Drives.ToXmlData()).root.VolumeOrPartitionId.MountPoint | Select -Unique) + " " + ($Object.AuxData.OriginalDiskFilter.IncludeMasks | Select -Unique)
                    $Additions += ([system.String]::Join(", ", $A)) -replace " , "
                }
                IF($Object.AuxData.OriginalDiskFilter.ExcludeMasks)
                {
                    $S = ($Object.AuxData.OriginalDiskFilter.ExcludeMasks | Select -Unique)
                    $Subtractions += ([system.String]::Join(", ", $S)) -replace " , "
                }
                $OSBackup = ($Object.AuxData.OriginalDiskFilter.BackupSystemState | Select -Unique)
                $UserBackup = ($Object.AuxData.OriginalDiskFilter.BackupUserFolders | Select -Unique)
            }
            $Members +=  $Object.Name + ", "
        }



        ###################################################
        FOREACH ($Backup in $Backups)
        {
            $Latest = $Backup.LastPointCreationTime
            $jobBackupSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.BackupSize | Measure-Object -Sum).Sum/1GB,1)}} ).Size
            $jobDataSize += ($Backup | Select @{N="Size";E={[math]::Round(($_.GetAllStorages().Stats.DataSize | Measure-Object -Sum).Sum/1GB,1)}}).Size
        }
        #Count Retention points        
        $Sessions = $Global:VBREPSession | where {($_.JobId -eq $Job.Id) -and ($_.EndTime -ge (Get-Date).addhours(-$Global:AuditHours))}
        $Retention = ($Backups.GetPoints() | Measure-Object).count
        $IntervalSuccess = ($Sessions | Where {$_.Result -eq 'Success'}).count
        $IntervalWarning = ($Sessions | Where {$_.Result -eq 'Warning'}).count
        $IntervalFailure = ($Sessions | Where {$_.Result -eq 'Failed'}).count
        
        #Handling situations which results in blank fields
        IF ($Job.IsEnabled -ne "True")
        {
            $NextRun = 'Disabled'
        }
        ELSE
        {
            $NextRun = $Job.NextRun
        }

        #Cleanup trailing comma
        IF ($Members) 
        {
        $Members = $Members.Substring(0, $Members.Length - 2)
        }
        
        $Global:Data += [PSCustomObject]@{
            Name = $Job.Name
            Status = $Job.LastResult
            Enabled = $Job.IsEnabled
            Type = $Job.Type
            Schedule = $Interval
            NextRun = $NextRun
            LatestRun = $Latest
            Retention = $Retention
            BackupSize = $jobBackupSize
            DataSize = $jobDataSize
            IntervalSuccess = $IntervalSuccess
            IntervalWarning = $IntervalWarning
            IntervalFailure = $IntervalFailure
            Members = $Members
            Mode = $BackupMode
            Additions = $Additions
            Subtractions = $Subtractions
            OSBackedUp = $OSBackup
            UsersBackedUp = $UserBackup
            }
    }
}

Function CountErrors #Counts errors in event log
{
    $Errors = @(Get-EventLog -Log 'Veeam Backup' -EntryType Error -After (Get-Date).addhours(-$Global:AuditHours) -ErrorAction SilentlyContinue ).count
    IF ($Errors -gt 0)
    {
        $Global:CountErrors += $Errors
    }
}

Function License #Queries registry string to find expiration date for current license
{
    $key = "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication\license"
    Get-Item $key | select -Expand property | % {
        $value = (Get-ItemProperty -Path $key -Name $_).$_
        $Temp = [System.Text.Encoding]::Default.GetString($value)
    }
    $Temp = $Temp -split "Expiration date="
    $Temp2 = $Temp[1] -split "`r`n"
    $License = [datetime]::ParseExact($Temp2[0], "dd/mm/yyyy", $null) #Forces into date object, useful later to check for pending or passed expirations
    $Global:LicenseExpiration = $License
}

Function AppendData
{
    #Defines member properties so that it can be properly enumerated later
    $Global:Data | Add-Member -NotePropertyName 'LinkedJob' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'CloudProvider' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'License' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'Errors' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'AuditHours' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'Mode' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'Additions' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'Subtractions' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'OSBackedUp' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'UsersBackedUp' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'DiskSpace' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $Global:Data | Add-Member -NotePropertyName 'Version' -NotePropertyValue '' -ErrorAction SilentlyContinue
    $DiskSpace = ''
    $colDisks = get-wmiobject Win32_LogicalDisk -Filter 'DriveType = 3'
    foreach ($disk in $colDisks) 
    {
        if ($disk.size -gt 0)
        {
            $PercentFree = [Math]::round((($disk.freespace/$disk.size) * 100))
        } 
        else 
        {
            $PercentFree = 0
        }
        $Drive = $disk.DeviceID
        $DiskSpace += $Drive + $PercentFree + ","

    }
    IF ($DiskSpace) 
    {
    $DiskSpace = $DiskSpace.Substring(0, $DiskSpace.Length - 1)
    }
            
    #Adding up various totals
    $i=0;FOREACH($a in ($Global:Data | select BackupSize)){$i += $a.BackupSize}
    $j=0;FOREACH($a in ($Global:Data | select DataSize)){$j += $a.DataSize}
    $k=0;FOREACH($a in ($Global:Data | Where {$_.Enabled -eq 'True'} | select IntervalSuccess)){$k += $a.IntervalSuccess}
    $l=0;FOREACH($a in ($Global:Data | Where {$_.Enabled -eq 'True'} | select IntervalWarning)){$l += $a.IntervalWarning}
    $m=0;FOREACH($a in ($Global:Data | Where {$_.Enabled -eq 'True'} | select IntervalFailure)){$m += $a.IntervalFailure}

    $Global:Data += [PSCustomObject]@{
    Name = $env:COMPUTERNAME
    Type = 'BDR SUMMARY'
    BackupSize = $i
    DataSize = $j
    IntervalSuccess = $k
    IntervalWarning = $l
    IntervalFailure = $m
    Errors = $Global:CountErrors
    License = $Global:LicenseExpiration
    AuditHours = $Global:AuditHours
    DiskSpace = $DiskSpace 
    Version = $Global:Version
    }
}

Function Report1 #Problems
{
    #No Jobs Enabled   
    IF ((($Global:Data | Where {$_.Enabled -eq "True"} | Select Name).count) -eq 0)
    {
        $Global:Status = "ERROR: No Jobs Enabled."
        GenerateOutput
    }

    #All Jobs Failed
    IF ((($Global:Data | Where {($_.Status -eq "Success") -or ($_.Status -eq "Warning") -and ($_.Enabled -eq "True")}).count) -eq 0)
    {
        $Global:Status = "ERROR: All Jobs Failed."
        GenerateOutput
    }

    #Oldest success 2 weeks or more ago
    IF ((((Get-Date) - ([datetime](($Global:Data | Where {$_.LatestRun} | Where {$_.Enabled -eq 'True'} | Sort-Object { $_."LatestRun" -as [datetime] } | Select LatestRun | Select -First 1).LatestRun))).Days) -gt 14)
    {
        $Global:Status = "ERROR: Oldest Success " + (((Get-Date) - ([datetime](($Global:Data | Where {$_.LatestRun} | Where {$_.Enabled -eq 'True'} | Sort-Object { $_."LatestRun" -as [datetime] } | Select LatestRun | Select -First 1).LatestRun))).Days) + " Days Ago"
        GenerateOutput
    }

    #No success in audit window
    IF ((($Global:Data | Where {$_.Type -eq 'BDR SUMMARY'}).IntervalSuccess) -eq 0)
    {
        $Global:Status = "ERROR: No Success In Audit Window."
        GenerateOutput
    }

    #Expired License
    IF ( (((($Global:Data | Where {$_.License} | Select License).License) - (Get-Date)).Days) -lt 1 )
    {
        $Global:Status = "ERROR: License Expired"
        GenerateOutput
    }

    #Total Failed (Current status, not cumulative in audit window)
    IF (((($global:data | Where {$_.Status -eq "Failed"}).Name).count) -gt 0)
    {
        $Global:Status = "Failed: " + [String]((($global:data | Where {$_.Status -eq "Failed"}).Name).count)
        GenerateOutput
    } 
}

Function Report2 #Warnings / Errors
{
    #No Jobs Enabled   
    IF ((($Global:Data | Where {$_.Enabled -eq "True"} | Select Name).count) -eq 0)
    {
        $Global:Status = "ERROR: No Jobs Enabled."
        GenerateOutput
    }

    #All Jobs Failed
    IF ((($Global:Data | Where {($_.Status -eq "Success") -or ($_.Status -eq "Warning") -and ($_.Enabled -eq "True")}).count) -eq 0)
    {
        $Global:Status = "ERROR: All Jobs Failed."
        GenerateOutput
    }

    #Oldest success 2 weeks or more ago
    IF ((((Get-Date) - ([datetime](($Global:Data | Where {$_.LatestRun} | Where {$_.Enabled -eq 'True'} | Sort-Object { $_."LatestRun" -as [datetime] } | Select LatestRun | Select -First 1).LatestRun))).Days) -gt 14)
    {
        $Global:Status = "ERROR: Oldest Success " + (((Get-Date) - ([datetime](($Global:Data | Where {$_.LatestRun} | Where {$_.Enabled -eq 'True'} | Sort-Object { $_."LatestRun" -as [datetime] } | Select LatestRun | Select -First 1).LatestRun))).Days) + " Days Ago"
        GenerateOutput
    }

    #No success in audit window
    IF ((($Global:Data | Where {$_.Type -eq 'BDR SUMMARY'}).IntervalSuccess) -eq 0)
    {
        $Global:Status = "ERROR: No Success In Audit Window."
        GenerateOutput
    }

    #Expired License
    IF ( (((($Global:Data | Where {$_.License} | Select License).License) - (Get-Date)).Days) -lt 1 )
    {
        $Global:Status = "ERROR: License Expired"
        GenerateOutput
    }

    #Total Failed (Current status, not cumulative in audit window)
    IF (((($global:data | Where {$_.Status -eq "Failed"}).Name).count) -gt 0)
    {
        $Global:Status = "Failed: " + [String]((($global:data | Where {$_.Status -eq "Failed"}).Name).count)
        GenerateOutput
    } 

    #Total failures within audit window over 0
    IF ((($Global:Data | Where {$_.Type -eq 'BDR SUMMARY'}).IntervalFailure) -gt 0)
    {
        $Global:Status = "Failures: " + [String](($Global:Data | Where {$_.Type -eq 'BDR SUMMARY'}).IntervalFailure) + " In " + $Global:AuditHours + " Hours"
        GenerateOutput
    }
    
    #Total warnings within audit window over 0
    IF ((($Global:Data | Where {$_.Type -eq 'BDR SUMMARY'}).IntervalWarning) -gt 0)
    {
        $Global:Status = "Warnings: " + [String](($Global:Data | Where {$_.Type -eq 'BDR SUMMARY'}).IntervalWarning) + " In " + $Global:AuditHours + " Hours"
        GenerateOutput
    }

    #30 Days until license expires. 
    IF ( (((($Global:Data | Where {$_.License} | Select License).License) - (Get-Date)).Days) -lt 30 )
    {
        $Global:Status = "License < 30 Days"
        GenerateOutput
    }

    #Total count of event log errors
    IF ((($Global:Data | Where {$_.Errors} | Select Errors).Errors) -gt 0)
    {
        $Global:Status = "Errors: " + [String](($Global:Data | Where {$_.Errors} | Select Errors).Errors) + " In " + $Global:AuditHours + " Hours"
        GenerateOutput
    }
}

Function Report3 #Date License Expires
{
    $Global:Status = (($Global:Data | Where {$_.License} | Select License).License)
    GenerateOutput
}

Function Report4 #Days since last job succeeded
{
    $Global:Status = (((Get-Date) - ([datetime](($Global:Data | Where {$_.LatestRun} | Where {$_.Enabled -eq 'True'} | Sort-Object { $_."LatestRun" -as [datetime] } | Select LatestRun | Select -First 1).LatestRun))).Days)
    GenerateOutput   
}

Function Report5
{
    $Global:Data | export-csv C:\temp\VeeamAudit.csv
}

cls
#FUNCTION CALLS

ServiceCheck
LoadSnapIn
GetVersion
WarnLowDisk
GatherData
PopulateBackups
PopulateOffsites
PopulateAgents
PopulateAgentPolicy
PopulateDirectAgents
CountErrors
License
AppendData


IF ($Global:ReportSelection -eq 2)
{
    Write-Host "RUNNING REPORT 2"
    Report2
}
ELSEIF ($Global:ReportSelection -eq 3)
{
    Write-Host "RUNNING REPORT 3"
    Report3
}
ELSEIF ($Global:ReportSelection -eq 4)
{
    Write-Host "RUNNING REPORT 4"
    Report4
}
ELSEIF ($Global:ReportSelection -eq 5)
{
    Write-Host "RUNNING REPORT 5"
    Report5
}
ELSE
{
    Write-Host "RUNNING REPORT 1"
    Report1
}

#Host Output
#$Global:Data 

