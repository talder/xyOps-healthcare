#requires -Version 7.0
# Copyright (c) 2026 Tim Alderweireldt. All rights reserved.
<#!
xyOps Healthcare Event Plugin (PowerShell 7)
Healthcare interoperability tools for xyOps:
- HL7 Message Generator (v2.x messages with fake or custom data)
- HL7 Message Parser (parse, analyze, validate HL7 messages)

I/O contract:
- Read one JSON object from STDIN (job), write progress/messages as JSON lines of the
  form: { "xy": 1, ... } to STDOUT.
- On success, emit: { "xy": 1, "code": 0, "data": <result>, "description": "..." }
- On error, emit:   { "xy": 1, "code": <nonzero>, "description": "..." } and exit 1.

Test locally:
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\healthcare.ps1 < job.json
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-XY {
  param([hashtable]$Object)
  $payload = [ordered]@{ xy = 1 }
  foreach ($k in $Object.Keys) { $payload[$k] = $Object[$k] }
  [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 20 -Compress))
  [Console]::Out.Flush()
}

function Write-XYProgress {
  param([double]$Value, [string]$Status)
  $o = @{ progress = [math]::Round($Value, 4) }
  if ($Status) { $o.status = $Status }
  Write-XY $o
}

function Write-XYSuccess {
  param($Data, [string]$Description)
  $o = @{ code = 0; data = $Data }
  if ($Description) { $o.description = $Description }
  Write-XY $o
}

function Write-XYError {
  param([int]$Code, [string]$Description)
  Write-XY @{ code = $Code; description = $Description }
}

function Read-JobFromStdin {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { throw 'No job JSON received on STDIN' }
  return $raw | ConvertFrom-Json -ErrorAction Stop
}

function Get-NestedValue {
  param($Object, [string]$Path)
  if (-not $Path -or ($Path.Trim() -eq '')) { return $Object }
  $cur = $Object
  foreach ($part in $Path.Split('.')) {
    if ($null -eq $cur) { return $null }
    if ($cur -is [System.Collections.IDictionary]) {
      if (-not $cur.Contains($part)) { return $null }
      $cur = $cur[$part]
    }
    else {
      $cur = $cur.PSObject.Properties[$part].Value
    }
  }
  return $cur
}

function Get-Param {
  param($Params, [string]$Name, $Default = $null)
  if ($Params.PSObject.Properties.Name -contains $Name) { return $Params.$Name }
  return $Default
}

function Get-RandomBytes {
  param([int]$Length)
  $data = New-Object byte[] ($Length)
  [void][System.Security.Cryptography.RandomNumberGenerator]::Fill($data)
  return $data
}

function Get-SecureRandomInt {
  [OutputType([int])]
  param([int]$Max)
  # Use Get-Random for reliability (still cryptographically seeded in PS7)
  return [int](Get-Random -Maximum $Max)
}

function Get-SecureRandomString {
  [OutputType([string])]
  param([int]$Length)
  $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  $sb = [System.Text.StringBuilder]::new($Length)
  for ([int]$i = 0; $i -lt $Length; $i++) {
    [int]$idx = Get-SecureRandomInt $chars.Length
    [void]$sb.Append($chars[$idx])
  }
  return $sb.ToString()
}

# ------------------------- HL7 Message Generator -------------------------
function Invoke-HL7Generator {
  param($Params, $JobInput, [string]$Cwd)
  Write-XYProgress 0.1 'Validating parameters...'
  
  $messageType = (Get-Param $Params 'hl7MessageType' 'ADT')
  $eventType = (Get-Param $Params 'hl7EventType' 'A01')
  $version = '2.5.1'
  $dataSource = (Get-Param $Params 'hl7DataSource' 'field')
  $dataPath = (Get-Param $Params 'hl7DataPath' '')
  
  $validationErrors = [System.Collections.Generic.List[string]]::new()
  
  # Helper to get non-empty param value or null
  $getField = { param($name) $v = $Params.$name; if ($v -and $v.Trim()) { $v.Trim() } else { $null } }
  
  # Initialize bucket data (empty hashtable if not using bucket)
  $bucket = @{}
  
  if ($dataSource -eq 'bucket') {
    $inputData = $JobInput.data
    if (-not $inputData) {
      $validationErrors.Add('Bucket data source selected but no input data available from previous job')
    } else {
      # Get data at path prefix (or root if empty)
      $sourceData = if ($dataPath.Trim()) { Get-NestedValue $inputData $dataPath } else { $inputData }
      if ($null -eq $sourceData) {
        $validationErrors.Add("Data path '$dataPath' not found in bucket data")
      } else {
        # Convert PSObject to hashtable for easy access
        if ($sourceData -is [PSCustomObject]) {
          $sourceData.PSObject.Properties | ForEach-Object { $bucket[$_.Name] = $_.Value }
        } elseif ($sourceData -is [hashtable]) {
          $bucket = $sourceData
        }
      }
    }
  }
  
  # Helper to get value: form field overrides bucket, bucket overrides null
  $getValue = { param($fieldName, $bucketKey)
    $formVal = & $getField $fieldName
    if ($formVal) { return $formVal }
    if ($bucket.ContainsKey($bucketKey)) { 
      $v = $bucket[$bucketKey]
      if ($v -and "$v".Trim()) { return "$v".Trim() }
    }
    return $null
  }
  
  # Read values (form fields override bucket data)
  # Patient demographics
  $inputPatientId = & $getValue 'hl7PatientId' 'patientId'
  $inputPatientFirstName = & $getValue 'hl7PatientFirstName' 'patientFirstName'
  $inputPatientMiddleName = & $getValue 'hl7PatientMiddleName' 'patientMiddleName'
  $inputPatientLastName = & $getValue 'hl7PatientLastName' 'patientLastName'
  $inputPatientDOB = & $getValue 'hl7PatientDOB' 'patientDOB'
  $inputPatientGender = & $getValue 'hl7PatientGender' 'patientGender'
  $inputPatientSSN = & $getValue 'hl7PatientSSN' 'patientSSN'
  $inputPatientRace = & $getValue 'hl7PatientRace' 'patientRace'
  $inputPatientMaritalStatus = & $getValue 'hl7PatientMaritalStatus' 'patientMaritalStatus'
  $inputPatientAddress = & $getValue 'hl7PatientAddress' 'patientAddress'
  $inputPatientCity = & $getValue 'hl7PatientCity' 'patientCity'
  $inputPatientState = & $getValue 'hl7PatientState' 'patientState'
  $inputPatientZip = & $getValue 'hl7PatientZip' 'patientZip'
  $inputPatientPhone = & $getValue 'hl7PatientPhone' 'patientPhone'
  # Visit information
  $inputAttendingId = & $getValue 'hl7AttendingId' 'attendingId'
  $inputAttendingFirstName = & $getValue 'hl7AttendingFirstName' 'attendingFirstName'
  $inputAttendingLastName = & $getValue 'hl7AttendingLastName' 'attendingLastName'
  $inputVisitNumber = & $getValue 'hl7VisitNumber' 'visitNumber'
  $inputPatientClass = & $getValue 'hl7PatientClass' 'patientClass'
  $inputAssignedLocation = & $getValue 'hl7AssignedLocation' 'assignedLocation'
  $inputAdmitDateTime = & $getValue 'hl7AdmitDateTime' 'admitDateTime'
  $inputDischargeDateTime = & $getValue 'hl7DischargeDateTime' 'dischargeDateTime'
  $inputAdmitReason = & $getValue 'hl7AdmitReason' 'admitReason'
  # Diagnosis
  $inputDiagnosisCode = & $getValue 'hl7DiagnosisCode' 'diagnosisCode'
  $inputDiagnosisDescription = & $getValue 'hl7DiagnosisDescription' 'diagnosisDescription'
  # Message header
  $inputSendingApp = & $getValue 'hl7SendingApp' 'sendingApp'
  $inputSendingFacility = & $getValue 'hl7SendingFacility' 'sendingFacility'
  $inputReceivingApp = & $getValue 'hl7ReceivingApp' 'receivingApp'
  $inputReceivingFacility = & $getValue 'hl7ReceivingFacility' 'receivingFacility'
  
  # Validate specific field formats
  if ($inputPatientDOB -and $inputPatientDOB -notmatch '^\d{8}$') {
    $validationErrors.Add("Patient DOB must be in YYYYMMDD format (e.g., 19850315)")
  }
  if ($inputAdmitDateTime -and $inputAdmitDateTime -notmatch '^\d{12}$') {
    $validationErrors.Add("Admit Date/Time must be in YYYYMMDDHHmm format (e.g., 202601151030)")
  }
  if ($inputDischargeDateTime -and $inputDischargeDateTime -notmatch '^\d{12}$') {
    $validationErrors.Add("Discharge Date/Time must be in YYYYMMDDHHmm format (e.g., 202601201400)")
  }
  
  if ($validationErrors.Count -gt 0) {
    Write-XY @{ table = @{ title='Validation Errors'; header=@('#','Error'); rows=@(for ($n = 0; $n -lt $validationErrors.Count; $n++) { ,@(($n + 1), $validationErrors[$n]) }); caption='Please fix the errors above' } }
    throw "Validation failed with $($validationErrors.Count) error(s)"
  }
  
  Write-XYProgress 0.3 'Generating fake data...'
  
  $firstNames = @('James','Mary','John','Patricia','Robert','Jennifer','Michael','Linda','David','Elizabeth','William','Barbara')
  $lastNames = @('Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez')
  $streets = @('Main St','Oak Ave','Maple Dr','Cedar Ln','Pine Rd','Elm St','Park Ave')
  $cities = @('New York','Los Angeles','Chicago','Houston','Phoenix','Philadelphia')
  $states = @('NY','CA','IL','TX','AZ','PA','FL','OH','NC','WA')
  
  # Generate default values
  $now = Get-Date
  $msgControlId = Get-SecureRandomString 10
  
  # Handle select fields with 'random' option
  $genderValue = if ($inputPatientGender -and $inputPatientGender -ne 'random') { $inputPatientGender.ToUpper() } else { @('M','F')[(Get-SecureRandomInt 2)] }
  $raceValue = if ($inputPatientRace -and $inputPatientRace -ne 'random') { $inputPatientRace } else { @('2106-3','2054-5','2028-9','2076-8','1002-5')[(Get-SecureRandomInt 5)] }
  $maritalValue = if ($inputPatientMaritalStatus -and $inputPatientMaritalStatus -ne 'random') { $inputPatientMaritalStatus } else { @('S','M','D','W')[(Get-SecureRandomInt 4)] }
  $classValue = if ($inputPatientClass -and $inputPatientClass -ne 'random') { $inputPatientClass } else { @('I','O','E','P')[(Get-SecureRandomInt 4)] }
  
  # Calculate random DOB (age 18-68) - hardcoded to avoid any array issues
  [int]$birthYear = 1958 + (Get-Random -Maximum 51)
  [int]$birthMonth = 1 + (Get-Random -Maximum 12)
  [int]$birthDay = 1 + (Get-Random -Maximum 28)
  [string]$defaultDOB = '{0:D4}{1:D2}{2:D2}' -f $birthYear, $birthMonth, $birthDay
  
  $d = @{
    patientId = $inputPatientId ?? (Get-SecureRandomString 8)
    patientLastName = $inputPatientLastName ?? $lastNames[(Get-SecureRandomInt $lastNames.Count)]
    patientFirstName = $inputPatientFirstName ?? $firstNames[(Get-SecureRandomInt $firstNames.Count)]
    patientMiddleName = $inputPatientMiddleName ?? ''
    patientDOB = $inputPatientDOB ?? $defaultDOB
    patientGender = $genderValue
    patientSSN = $inputPatientSSN ?? "$((Get-SecureRandomInt 900)+100)-$((Get-SecureRandomInt 90)+10)-$((Get-SecureRandomInt 9000)+1000)"
    patientAddress = $inputPatientAddress ?? "$((Get-SecureRandomInt 9999)+1) $($streets[(Get-SecureRandomInt $streets.Count)])"
    patientCity = $inputPatientCity ?? $cities[(Get-SecureRandomInt $cities.Count)]
    patientState = $inputPatientState ?? $states[(Get-SecureRandomInt $states.Count)]
    patientZip = $inputPatientZip ?? ('{0:D5}' -f ((Get-SecureRandomInt 90000)+10000))
    patientPhone = $inputPatientPhone ?? "($((Get-SecureRandomInt 900)+100))$((Get-SecureRandomInt 900)+100)-$((Get-SecureRandomInt 9000)+1000)"
    patientRace = $raceValue
    patientMaritalStatus = $maritalValue
    attendingId = $inputAttendingId ?? (Get-SecureRandomString 6)
    attendingLastName = $inputAttendingLastName ?? $lastNames[(Get-SecureRandomInt $lastNames.Count)]
    attendingFirstName = $inputAttendingFirstName ?? $firstNames[(Get-SecureRandomInt $firstNames.Count)]
    visitNumber = $inputVisitNumber ?? (Get-SecureRandomString 10)
    admitDateTime = $inputAdmitDateTime ?? $now.ToString('yyyyMMddHHmm')
    dischargeDateTime = $inputDischargeDateTime ?? $now.AddDays([int](Get-SecureRandomInt 5)+1).ToString('yyyyMMddHHmm')
    patientClass = $classValue
    assignedLocation = $inputAssignedLocation ?? "ROOM$((Get-SecureRandomInt 500)+100)^BED$((Get-SecureRandomInt 4)+1)^FLOOR$((Get-SecureRandomInt 5)+1)"
    admitReason = $inputAdmitReason ?? @('Chest pain','Shortness of breath','Abdominal pain','Fever','Injury')[(Get-SecureRandomInt 5)]
    diagnosisCode = $inputDiagnosisCode ?? @('I10','J18.9','K35.80','R50.9','S82.90')[(Get-SecureRandomInt 5)]
    diagnosisDescription = $inputDiagnosisDescription ?? @('Essential hypertension','Pneumonia','Acute appendicitis','Fever','Fracture of leg')[(Get-SecureRandomInt 5)]
    orderNumber = Get-SecureRandomString 10
    orderDateTime = $now.ToString('yyyyMMddHHmm')
    orderingProviderId = Get-SecureRandomString 6
    orderingProviderName = "$($lastNames[(Get-SecureRandomInt $lastNames.Count)])^$($firstNames[(Get-SecureRandomInt $firstNames.Count)])"
    observationId = @('2345-7','2339-0','718-7','2160-0','3094-0')[(Get-SecureRandomInt 5)]
    observationValue = "$((Get-SecureRandomInt 100)+50)"
    observationUnits = @('mg/dL','mmol/L','g/dL','mEq/L','U/L')[(Get-SecureRandomInt 5)]
    observationDateTime = $now.ToString('yyyyMMddHHmm')
    observationStatus = 'F'
    appointmentId = Get-SecureRandomString 8
    appointmentDateTime = $now.AddDays([int](Get-SecureRandomInt 30)+1).ToString('yyyyMMddHHmm')
    appointmentDuration = '30'
    appointmentType = @('CHECKUP','FOLLOWUP','CONSULT','PROCEDURE')[(Get-SecureRandomInt 4)]
    appointmentStatus = 'Booked'
    medicationCode = @('197361','311671','308182','198211','197380')[(Get-SecureRandomInt 5)]
    medicationName = @('Lisinopril 10mg','Metformin 500mg','Omeprazole 20mg','Atorvastatin 40mg','Amlodipine 5mg')[(Get-SecureRandomInt 5)]
    medicationDose = @('10','500','20','40','5')[(Get-SecureRandomInt 5)]
    medicationRoute = 'PO'
    medicationFrequency = @('QD','BID','TID','QID')[(Get-SecureRandomInt 4)]
    documentType = @('DS','HP','OP','CN','PN')[(Get-SecureRandomInt 5)]
    documentStatus = @('AU','DI','DO','IN')[(Get-SecureRandomInt 4)]
    documentDateTime = $now.ToString('yyyyMMddHHmm')
    sendingApp = $inputSendingApp ?? 'XYOPS'
    sendingFacility = $inputSendingFacility ?? 'HOSPITAL'
    receivingApp = $inputReceivingApp ?? 'RECEIVER'
    receivingFacility = $inputReceivingFacility ?? 'CLINIC'
  }
  
  Write-XYProgress 0.5 'Building HL7 message...'
  
  $segments = [System.Collections.Generic.List[string]]::new()
  $segmentInfo = [System.Collections.Generic.List[object]]::new()
  
  # MSH - Message Header (always first)
  $msh = "MSH|^~\&|$($d.sendingApp)|$($d.sendingFacility)|$($d.receivingApp)|$($d.receivingFacility)|$($now.ToString('yyyyMMddHHmmss'))||$messageType^$eventType|$msgControlId|P|$version"
  $segments.Add($msh)
  $segmentInfo.Add(@('MSH', 'Message Header', 'Identifies sender, receiver, message type, and version'))
  
  # EVN - Event Type
  $evn = "EVN|$eventType|$($now.ToString('yyyyMMddHHmmss'))"
  $segments.Add($evn)
  $segmentInfo.Add(@('EVN', 'Event Type', "Event: $eventType"))
  
  # PID - Patient Identification (for most messages)
  if ($messageType -in @('ADT','ORM','ORU','SIU','RDE','MDM','DFT','VXU')) {
    $pidSeg = "PID|1||$($d.patientId)^^^MRN||$($d.patientLastName)^$($d.patientFirstName)^$($d.patientMiddleName)||$($d.patientDOB)|$($d.patientGender)||$($d.patientRace)|$($d.patientAddress)^^$($d.patientCity)^$($d.patientState)^$($d.patientZip)||$($d.patientPhone)||||$($d.patientMaritalStatus)||||||$($d.patientSSN)"
    $segments.Add($pidSeg)
    $segmentInfo.Add(@('PID', 'Patient Identification', "Patient: $($d.patientFirstName) $($d.patientLastName), MRN: $($d.patientId)"))
  }
  
  # PV1 - Patient Visit
  if ($messageType -in @('ADT','ORM','ORU','SIU','RDE','DFT')) {
    $pv1 = "PV1|1|$($d.patientClass)|$($d.assignedLocation)|||$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)||||||||||||$($d.visitNumber)|||||||||||||||||||||||||||$($d.admitDateTime)"
    $segments.Add($pv1)
    $segmentInfo.Add(@('PV1', 'Patient Visit', "Visit: $($d.visitNumber), Class: $($d.patientClass)"))
  }
  
  # Message-specific segments
  switch ($messageType) {
    'ADT' {
      $dg1 = "DG1|1||$($d.diagnosisCode)^$($d.diagnosisDescription)^ICD10||$($now.ToString('yyyyMMddHHmmss'))|A"
      $segments.Add($dg1)
      $segmentInfo.Add(@('DG1', 'Diagnosis', "Diagnosis: $($d.diagnosisCode) - $($d.diagnosisDescription)"))
      if ($eventType -eq 'A03') {
        $pv2 = "PV2||||||||$($d.dischargeDateTime)"
        $segments.Add($pv2)
        $segmentInfo.Add(@('PV2', 'Patient Visit Additional', "Discharge: $($d.dischargeDateTime)"))
      }
    }
    'ORM' {
      $orc = "ORC|NW|$($d.orderNumber)||||||||||$($d.orderingProviderId)^$($d.orderingProviderName)"
      $segments.Add($orc)
      $segmentInfo.Add(@('ORC', 'Common Order', "Order: $($d.orderNumber)"))
      $obr = "OBR|1|$($d.orderNumber)||$($d.observationId)^Complete Blood Count^LN|||$($d.orderDateTime)||||||||$($d.orderingProviderId)^$($d.orderingProviderName)"
      $segments.Add($obr)
      $segmentInfo.Add(@('OBR', 'Observation Request', "Test: $($d.observationId)"))
    }
    'ORU' {
      $obr = "OBR|1|$($d.orderNumber)||$($d.observationId)^Lab Test^LN|||$($d.observationDateTime)||||||||$($d.orderingProviderId)^$($d.orderingProviderName)||||||||F"
      $segments.Add($obr)
      $segmentInfo.Add(@('OBR', 'Observation Request', "Test: $($d.observationId)"))
      $obx = "OBX|1|NM|$($d.observationId)^Glucose^LN||$($d.observationValue)|$($d.observationUnits)|70-100|N|||$($d.observationStatus)|||$($d.observationDateTime)"
      $segments.Add($obx)
      $segmentInfo.Add(@('OBX', 'Observation Result', "Result: $($d.observationValue) $($d.observationUnits)"))
    }
    'SIU' {
      $sch = "SCH|$($d.appointmentId)||||||$($d.appointmentType)|$($d.appointmentType)^$($d.appointmentType)^HL70276|$($d.appointmentDuration)|MIN|^^$($d.appointmentDuration)^$($d.appointmentDateTime)|$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)||||$($d.appointmentStatus)"
      $segments.Add($sch)
      $segmentInfo.Add(@('SCH', 'Scheduling Activity', "Appointment: $($d.appointmentId), Type: $($d.appointmentType)"))
      $ais = "AIS|1||$($d.appointmentType)^$($d.appointmentType)||$($d.appointmentDateTime)|$($d.appointmentDuration)|MIN"
      $segments.Add($ais)
      $segmentInfo.Add(@('AIS', 'Appointment Info', "Duration: $($d.appointmentDuration) min"))
    }
    'RDE' {
      $orc = "ORC|NW|$($d.orderNumber)||||||||||$($d.orderingProviderId)^$($d.orderingProviderName)"
      $segments.Add($orc)
      $segmentInfo.Add(@('ORC', 'Common Order', "Order: $($d.orderNumber)"))
      $rxe = "RXE|^^^$($d.orderDateTime)^^R|$($d.medicationCode)^$($d.medicationName)^NDC|$($d.medicationDose)||$($d.medicationUnits ?? 'mg')|||||||||||||$($d.medicationRoute)||$($d.medicationFrequency)"
      $segments.Add($rxe)
      $segmentInfo.Add(@('RXE', 'Pharmacy Encoded Order', "Medication: $($d.medicationName)"))
    }
    'MDM' {
      $txa = "TXA|1|$($d.documentType)|TX|$($d.documentDateTime)||||||$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)||$msgControlId||||||$($d.documentStatus)"
      $segments.Add($txa)
      $segmentInfo.Add(@('TXA', 'Document Header', "Document Type: $($d.documentType), Status: $($d.documentStatus)"))
      $obx = "OBX|1|TX|$($d.documentType)^Clinical Document||Patient presents with $($d.admitReason). Assessment and plan documented.||||||F"
      $segments.Add($obx)
      $segmentInfo.Add(@('OBX', 'Document Content', 'Clinical note content'))
    }
    'DFT' {
      $ft1 = "FT1|1|||$($d.orderDateTime)||CG|$($d.diagnosisCode)^$($d.diagnosisDescription)^ICD10||1||||||$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)|||||$($d.diagnosisCode)^$($d.diagnosisDescription)^ICD10"
      $segments.Add($ft1)
      $segmentInfo.Add(@('FT1', 'Financial Transaction', "Charge: $($d.diagnosisCode)"))
    }
    'VXU' {
      $orc = "ORC|RE|$($d.orderNumber)"
      $segments.Add($orc)
      $segmentInfo.Add(@('ORC', 'Common Order', "Order: $($d.orderNumber)"))
      $rxa = "RXA|0|1|$($d.orderDateTime)|$($d.orderDateTime)|$($d.medicationCode)^$($d.medicationName)^CVX|999|||||||||||||||A"
      $segments.Add($rxa)
      $segmentInfo.Add(@('RXA', 'Vaccine Administration', "Vaccine: $($d.medicationName)"))
    }
  }
  
  Write-XYProgress 0.8 'Saving HL7 file...'
  
  $hl7Message = $segments -join "`r"
  $filename = "hl7-$messageType-$eventType-$msgControlId.hl7"
  $outputPath = Join-Path $Cwd $filename
  $hl7Message | Out-File -FilePath $outputPath -Encoding UTF8 -NoNewline
  
  Write-XYProgress 0.95 'Finalizing...'
  
  Write-XY @{ files = @($filename) }
  Write-XY @{ table = @{ title='HL7 Message Segments'; header=@('Segment','Name','Description'); rows=$segmentInfo.ToArray(); caption="$messageType^$eventType message generated" } }
  Write-XY @{ text = @{ title='Raw HL7 Message'; content=$hl7Message; caption='' } }
  
  [pscustomobject]@{ tool='HL7 Generator'; messageType=$messageType; eventType=$eventType; version=$version; controlId=$msgControlId; segments=$segments.ToArray(); file=$filename; message=$hl7Message }
}

# ------------------------- HL7 Message Parser -------------------------
function Invoke-HL7Parser {
  param($Params, $JobInput, [string]$Cwd)
  Write-XYProgress 0.1 'Validating parameters...'
  
  $source = ($Params.hl7ParserSource ?? 'field')
  $hl7Input = ''
  
  if ($source -eq 'file') {
    $filePath = ($Params.hl7FilePath ?? '')
    if (-not $filePath) { throw 'No file path provided' }
    $fullPath = if ([System.IO.Path]::IsPathRooted($filePath)) { $filePath } else { Join-Path $Cwd $filePath }
    if (-not (Test-Path $fullPath)) { throw "File not found: $filePath" }
    $hl7Input = Get-Content -Path $fullPath -Raw
  } elseif ($source -eq 'bucket') {
    $inputData = $JobInput.data
    if (-not $inputData) { throw 'Bucket data source selected but no input data available from previous job' }
    $path = (Get-Param $Params 'hl7ParserDataPath' '')
    $val = if ($path.Trim()) { Get-NestedValue $inputData $path } else { $inputData }
    if ($null -eq $val) { throw "Data path '$path' not found in bucket data" }
    # Handle if bucket contains the message directly or in a 'message' field
    if ($val -is [PSCustomObject] -or $val -is [hashtable]) {
      # Try common field names
      $hl7Input = $val.message ?? $val.hl7Message ?? $val.hl7 ?? $val.content ?? $val.data ?? ''
      if (-not $hl7Input) { throw "Bucket data is an object but no 'message', 'hl7Message', 'hl7', 'content', or 'data' field found" }
    } else {
      $hl7Input = [string]$val
    }
  } else {
    $hl7Input = ($Params.hl7Input ?? '')
  }
  
  if (-not $hl7Input.Trim()) { throw 'No HL7 message provided' }
  
  Write-XYProgress 0.3 'Parsing HL7 message...'
  
  $hl7Input = $hl7Input -replace "`r`n", "`r" -replace "`n", "`r"
  $lines = $hl7Input.Trim() -split "`r" | Where-Object { $_.Trim() }
  
  if ($lines.Count -eq 0) { throw 'Empty HL7 message' }
  
  $mshLine = $lines[0]
  if (-not $mshLine.StartsWith('MSH')) { throw 'HL7 message must start with MSH segment' }
  
  $fieldSep = $mshLine[3]
  $compSep = $mshLine[4]
  
  $errors = [System.Collections.Generic.List[string]]::new()
  $warnings = [System.Collections.Generic.List[string]]::new()
  $parsedSegments = [System.Collections.Generic.List[object]]::new()
  $segmentRows = [System.Collections.Generic.List[object]]::new()
  
  $segmentDefs = @{
    'MSH' = @{ name='Message Header'; required=$true; fields=@('Encoding Characters','Sending Application','Sending Facility','Receiving Application','Receiving Facility','Date/Time','Security','Message Type','Control ID','Processing ID','Version') }
    'EVN' = @{ name='Event Type'; required=$false; fields=@('Event Type Code','Recorded Date/Time','Planned Event Date/Time','Event Reason Code','Operator ID') }
    'PID' = @{ name='Patient Identification'; required=$false; fields=@('Set ID','External ID','Internal ID','Alternate ID','Patient Name','Mother Maiden Name','DOB','Gender','Alias','Race','Address','County','Phone Home','Phone Business','Language','Marital Status','Religion','Account','SSN') }
    'PV1' = @{ name='Patient Visit'; required=$false; fields=@('Set ID','Patient Class','Assigned Location','Admission Type','Preadmit Number','Prior Location','Attending Doctor','Referring Doctor','Consulting Doctor','Hospital Service') }
    'PV2' = @{ name='Patient Visit Additional'; required=$false; fields=@('Prior Pending Location','Accommodation Code','Admit Reason','Transfer Reason','Patient Valuables','Patient Valuables Location','Visit User Code','Expected Admit Date','Expected Discharge Date') }
    'DG1' = @{ name='Diagnosis'; required=$false; fields=@('Set ID','Coding Method','Diagnosis Code','Description','Date/Time','Type','Category','Related Group','Approval Indicator') }
    'ORC' = @{ name='Common Order'; required=$false; fields=@('Order Control','Placer Order Number','Filler Order Number','Placer Group Number','Order Status','Response Flag','Quantity/Timing','Parent','Date/Time Transaction','Entered By','Verified By','Ordering Provider') }
    'OBR' = @{ name='Observation Request'; required=$false; fields=@('Set ID','Placer Order Number','Filler Order Number','Universal Service ID','Priority','Requested Date/Time','Observation Date/Time','Observation End Date/Time','Collection Volume','Collector ID','Specimen Action Code','Danger Code','Clinical Info','Received Date/Time','Specimen Source','Ordering Provider') }
    'OBX' = @{ name='Observation Result'; required=$false; fields=@('Set ID','Value Type','Observation ID','Sub-ID','Observation Value','Units','Reference Range','Abnormal Flags','Probability','Nature','Status','Effective Date','User Defined Access Checks','Date/Time Observation') }
    'SCH' = @{ name='Scheduling Activity'; required=$false; fields=@('Placer Appointment ID','Filler Appointment ID','Occurrence Number','Placer Group Number','Schedule ID','Event Reason','Appointment Reason','Appointment Type','Appointment Duration','Duration Units') }
    'AIS' = @{ name='Appointment Information'; required=$false; fields=@('Set ID','Segment Action Code','Universal Service ID','Start Date/Time','Start Offset','Start Offset Units','Duration','Duration Units','Allow Substitution Code','Filler Status Code') }
    'RXE' = @{ name='Pharmacy Encoded Order'; required=$false; fields=@('Quantity/Timing','Give Code','Give Amount Minimum','Give Amount Maximum','Give Units','Give Dosage Form','Admin Instructions','Deliver-to Location') }
    'RXA' = @{ name='Pharmacy Administration'; required=$false; fields=@('Give Sub-ID Counter','Admin Sub-ID Counter','Date/Time Start','Date/Time End','Administered Code','Administered Amount','Administered Units','Administered Dosage Form','Admin Notes','Administering Provider') }
    'TXA' = @{ name='Transcription Document Header'; required=$false; fields=@('Set ID','Document Type','Content Presentation','Activity Date/Time','Primary Activity Provider','Origination Date/Time','Transcription Date/Time','Edit Date/Time','Originator Code','Assigned Document Authenticator') }
    'FT1' = @{ name='Financial Transaction'; required=$false; fields=@('Set ID','Transaction ID','Transaction Batch ID','Transaction Date','Transaction Posting Date','Transaction Type','Transaction Code','Transaction Description','Transaction Quantity','Extended Amount') }
  }
  
  Write-XYProgress 0.5 'Analyzing segments...'
  
  $messageType = ''; $eventType = ''; $version = ''; $controlId = ''
  
  foreach ($line in $lines) {
    if (-not $line.Trim()) { continue }
    
    $segmentId = $line.Substring(0, [Math]::Min(3, $line.Length))
    
    $fields = if ($segmentId -eq 'MSH') {
      @('MSH', $fieldSep) + ($line.Substring(4) -split [regex]::Escape($fieldSep))
    } else {
      $line -split [regex]::Escape($fieldSep)
    }
    
    $segmentName = $segmentDefs[$segmentId]?.name ?? 'Unknown'
    
    if ($segmentId -eq 'MSH') {
      if ($fields.Count -gt 9) {
        $msgTypeParts = $fields[9] -split [regex]::Escape($compSep)
        $messageType = $msgTypeParts[0]
        $eventType = if ($msgTypeParts.Count -gt 1) { $msgTypeParts[1] } else { '' }
      }
      if ($fields.Count -gt 10) { $controlId = $fields[10] }
      if ($fields.Count -gt 12) { $version = $fields[12] }
      
      if ($fields.Count -lt 12) { $errors.Add('MSH: Missing required fields (minimum 12 fields expected)') }
      if (-not $messageType) { $errors.Add('MSH-9: Message type is required') }
      if (-not $controlId) { $errors.Add('MSH-10: Control ID is required') }
      if (-not $version) { $warnings.Add('MSH-12: Version ID is missing') }
    }
    
    $fieldDetails = [System.Collections.Generic.List[object]]::new()
    $fieldDefs = $segmentDefs[$segmentId]?.fields ?? @()
    
    for ([int]$i = 1; $i -lt $fields.Count; $i++) {
      [int]$fieldIdx = $i - 1
      $fieldName = if ($i -le $fieldDefs.Count) { $fieldDefs[$fieldIdx] } else { "Field $i" }
      $fieldValue = $fields[$i]
      if ($fieldValue) {
        $fieldDetails.Add([pscustomobject]@{ index=$i; name=$fieldName; value=$fieldValue })
      }
    }
    
    $parsedSegments.Add([pscustomobject]@{
      segment = $segmentId
      name = $segmentName
      fields = $fieldDetails.ToArray()
      raw = $line
    })
    
    $preview = if ($line.Length -gt 60) { $line.Substring(0, 60) + '...' } else { $line }
    [int]$fieldCount = $fields.Count - 1
    $segmentRows.Add(@($segmentId, $segmentName, $fieldCount, $preview))
  }
  
  if (-not ($lines | Where-Object { $_.StartsWith('PID') })) {
    $warnings.Add('PID segment is missing - no patient identification')
  }
  
  Write-XYProgress 0.95 'Finalizing...'
  
  Write-XY @{ table = @{ title='HL7 Message Summary'; header=@('Property','Value'); rows=@(@('Message Type', "$messageType^$eventType"), @('Version', $version), @('Control ID', $controlId), @('Segments', $parsedSegments.Count), @('Errors', $errors.Count), @('Warnings', $warnings.Count)); caption=$(if ($errors.Count -eq 0) { 'Message parsed successfully' } else { 'Message has validation errors' }) } }
  
  Write-XY @{ table = @{ title='Segments'; header=@('Segment','Name','Fields','Preview'); rows=$segmentRows.ToArray(); caption='' } }
  
  if ($errors.Count -gt 0) {
    Write-XY @{ table = @{ title='Errors'; header=@('#','Error'); rows=@(for ($n = 0; $n -lt $errors.Count; $n++) { ,@(($n + 1), $errors[$n]) }); caption='Validation errors found' } }
  }
  if ($warnings.Count -gt 0) {
    Write-XY @{ table = @{ title='Warnings'; header=@('#','Warning'); rows=@(for ($n = 0; $n -lt $warnings.Count; $n++) { ,@(($n + 1), $warnings[$n]) }); caption='Validation warnings' } }
  }
  
  foreach ($seg in $parsedSegments) {
    if ($seg.fields.Count -gt 0) {
      $fieldRows = $seg.fields | ForEach-Object {
        [string]$valStr = "$($_.value)"
        $val = if ($valStr.Length -gt 50) { $valStr.Substring(0, 50) + '...' } else { $valStr }
        @("$($seg.segment)-$($_.index)", $_.name, $val)
      }
      Write-XY @{ table = @{ title="$($seg.segment) - $($seg.name)"; header=@('Field','Name','Value'); rows=$fieldRows; caption='' } }
    }
  }
  
  [pscustomobject]@{ tool='HL7 Parser'; messageType=$messageType; eventType=$eventType; version=$version; controlId=$controlId; segments=$parsedSegments.ToArray(); errors=$errors.ToArray(); warnings=$warnings.ToArray(); valid=($errors.Count -eq 0) }
}

# ------------------------- Main -------------------------
try {
  $job = Read-JobFromStdin
  $params = $job.params
  $tool = if ($params.PSObject.Properties.Name -contains 'tool') { $params.tool } else { 'hl7Generator' }
  $cwd = if ($job.PSObject.Properties.Name -contains 'cwd') { [string]$job.cwd } else { (Get-Location).Path }
  $jobInput = if ($job.PSObject.Properties.Name -contains 'input') { $job.input } else { @{} }

  $result = $null
  switch ($tool) {
    'hl7Generator' { $result = Invoke-HL7Generator -Params $params -JobInput $jobInput -Cwd $cwd }
    'hl7Parser'    { $result = Invoke-HL7Parser -Params $params -JobInput $jobInput -Cwd $cwd }
    default        { throw "Unknown tool: $tool" }
  }

  Write-XYSuccess -Data $result -Description ("{0} completed successfully" -f $result.tool)
  [Console]::Out.Flush()
  exit 0
}
catch {
  Write-XYError -Code 1 -Description ($_.Exception.Message)
  [Console]::Out.Flush()
  exit 1
}
