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
  if ($null -ne $Params -and $null -ne $Params.PSObject -and $Params.PSObject.Properties.Name -contains $Name) { return $Params.$Name }
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
  $userEventType = (Get-Param $Params 'hl7EventType' '')
  $version = '2.5.1'
  $dataSource = (Get-Param $Params 'hl7DataSource' 'field')
  $dataPath = (Get-Param $Params 'hl7DataPath' '')
  
  # Default event types per message type (HL7 v2.5.1 standard)
  $defaultEvents = @{
    'ADT' = 'A01'   # Admit patient
    'ORM' = 'O01'   # General order
    'ORU' = 'R01'   # Unsolicited observation result
    'SIU' = 'S12'   # Notification of new appointment
    'RDE' = 'O11'   # Pharmacy encoded order
    'MDM' = 'T02'   # Document status change notification
    'DFT' = 'P03'   # Post detail financial transaction
    'VXU' = 'V04'   # Unsolicited vaccination record update
  }
  
  # Valid event types per message type
  $validEvents = @{
    'ADT' = @('A01','A02','A03','A04','A05','A08','A11','A13','A28','A31')
    'ORM' = @('O01')
    'ORU' = @('R01')
    'SIU' = @('S12','S13','S14','S15','S16','S17')
    'RDE' = @('O11','O25')
    'MDM' = @('T01','T02','T03','T04','T05','T06','T07','T08','T09','T10','T11')
    'DFT' = @('P03','P11')
    'VXU' = @('V04')
  }
  
  # Determine event type: use user selection if valid for message type, otherwise use default
  $eventType = $defaultEvents[$messageType]
  if ($userEventType -and $validEvents[$messageType] -contains $userEventType) {
    $eventType = $userEventType
  }
  
  $validationErrors = [System.Collections.Generic.List[string]]::new()
  
  # Helper to get non-empty param value or null (safe under strict mode)
  $getField = { param($name) 
    $v = Get-Param $Params $name $null
    if ($v -and "$v".Trim()) { "$v".Trim() } else { $null }
  }
  
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
  
  # Gender-appropriate first names for semantic consistency
  $maleFirstNames = @('James','John','Robert','Michael','David','William','Richard','Joseph','Thomas','Christopher')
  $femaleFirstNames = @('Mary','Patricia','Jennifer','Linda','Elizabeth','Barbara','Susan','Jessica','Sarah','Karen')
  $lastNames = @('Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez')
  $streets = @('Main St','Oak Ave','Maple Dr','Cedar Ln','Pine Rd','Elm St','Park Ave')
  $cities = @('New York','Los Angeles','Chicago','Houston','Phoenix','Philadelphia')
  $states = @('NY','CA','IL','TX','AZ','PA','FL','OH','NC','WA')
  
  # Generate default values
  $now = Get-Date
  $msgControlId = Get-SecureRandomString 10
  
  # Handle select fields with 'random' option - determine gender first so name can match
  $genderValue = if ($inputPatientGender -and $inputPatientGender -ne 'random') { $inputPatientGender.ToUpper() } else { @('M','F')[(Get-SecureRandomInt 2)] }
  $raceValue = if ($inputPatientRace -and $inputPatientRace -ne 'random') { $inputPatientRace } else { @('2106-3','2054-5','2028-9','2076-8','1002-5')[(Get-SecureRandomInt 5)] }
  $maritalValue = if ($inputPatientMaritalStatus -and $inputPatientMaritalStatus -ne 'random') { $inputPatientMaritalStatus } else { @('S','M','D','W')[(Get-SecureRandomInt 4)] }
  $classValue = if ($inputPatientClass -and $inputPatientClass -ne 'random') { $inputPatientClass } else { @('I','O','E','P')[(Get-SecureRandomInt 4)] }
  
  # Select gender-appropriate first name if not provided by user
  $defaultFirstName = if ($genderValue -eq 'F') {
    $femaleFirstNames[(Get-SecureRandomInt $femaleFirstNames.Count)]
  } else {
    $maleFirstNames[(Get-SecureRandomInt $maleFirstNames.Count)]
  }
  
  # Calculate random DOB (age 18-68) - hardcoded to avoid any array issues
  [int]$birthYear = 1958 + (Get-Random -Maximum 51)
  [int]$birthMonth = 1 + (Get-Random -Maximum 12)
  [int]$birthDay = 1 + (Get-Random -Maximum 28)
  [string]$defaultDOB = '{0:D4}{1:D2}{2:D2}' -f $birthYear, $birthMonth, $birthDay
  
  $d = @{
    patientId = $inputPatientId ?? (Get-SecureRandomString 8)
    patientLastName = $inputPatientLastName ?? $lastNames[(Get-SecureRandomInt $lastNames.Count)]
    patientFirstName = $inputPatientFirstName ?? $defaultFirstName
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
    attendingFirstName = $inputAttendingFirstName ?? $maleFirstNames[(Get-SecureRandomInt $maleFirstNames.Count)]
    visitNumber = $inputVisitNumber ?? (Get-SecureRandomString 10)
    admitDateTime = $inputAdmitDateTime ?? $now.ToString('yyyyMMddHHmm')
    dischargeDateTime = $inputDischargeDateTime ?? $now.AddDays([int](Get-SecureRandomInt 5)+1).ToString('yyyyMMddHHmm')
    patientClass = $classValue
    assignedLocation = $inputAssignedLocation ?? "ROOM$((Get-SecureRandomInt 500)+100)^BED$((Get-SecureRandomInt 4)+1)^FLOOR$((Get-SecureRandomInt 5)+1)"
    admitReason = $inputAdmitReason ?? @('Chest pain','Shortness of breath','Abdominal pain','Fever','Injury')[(Get-SecureRandomInt 5)]
  }
  
  # Diagnosis data - paired code/description for consistency
  $diagnoses = @(
    @{ code='I10'; description='Essential hypertension' }
    @{ code='J18.9'; description='Pneumonia, unspecified organism' }
    @{ code='K35.80'; description='Unspecified acute appendicitis' }
    @{ code='R50.9'; description='Fever, unspecified' }
    @{ code='S82.90XA'; description='Unspecified fracture of lower leg, initial encounter' }
    @{ code='I21.9'; description='Acute myocardial infarction, unspecified' }
    @{ code='J44.1'; description='Chronic obstructive pulmonary disease with acute exacerbation' }
    @{ code='N39.0'; description='Urinary tract infection, site not specified' }
  )
  $selectedDiagnosis = $diagnoses[(Get-SecureRandomInt $diagnoses.Count)]
  $d['diagnosisCode'] = $inputDiagnosisCode ?? $selectedDiagnosis.code
  $d['diagnosisDescription'] = $inputDiagnosisDescription ?? $selectedDiagnosis.description
  # Add more fields to $d
  $d += @{
    orderNumber = Get-SecureRandomString 10
    orderDateTime = $now.ToString('yyyyMMddHHmm')
    orderingProviderId = Get-SecureRandomString 6
    orderingProviderName = "$($lastNames[(Get-SecureRandomInt $lastNames.Count)])^$($maleFirstNames[(Get-SecureRandomInt $maleFirstNames.Count)])"
    observationDateTime = $now.ToString('yyyyMMddHHmm')
    observationStatus = 'F'
  }
  
  # Lab test data (LOINC codes with names)
  $labTests = @(
    @{ id='2339-0'; name='Glucose [Mass/volume] in Blood'; shortName='Glucose'; units='mg/dL'; refLow=70; refHigh=100 }
    @{ id='2345-7'; name='Glucose [Mass/volume] in Serum or Plasma'; shortName='Glucose'; units='mg/dL'; refLow=70; refHigh=100 }
    @{ id='718-7';  name='Hemoglobin [Mass/volume] in Blood'; shortName='Hemoglobin'; units='g/dL'; refLow=12; refHigh=17 }
    @{ id='2160-0'; name='Creatinine [Mass/volume] in Serum or Plasma'; shortName='Creatinine'; units='mg/dL'; refLow=0.6; refHigh=1.2 }
    @{ id='3094-0'; name='Urea nitrogen [Mass/volume] in Serum or Plasma'; shortName='BUN'; units='mg/dL'; refLow=7; refHigh=20 }
  )
  $selectedLab = $labTests[(Get-SecureRandomInt $labTests.Count)]
  $d['observationId'] = $selectedLab.id
  $d['observationName'] = $selectedLab.name
  $d['observationShortName'] = $selectedLab.shortName
  $d['observationUnits'] = $selectedLab.units
  $d['observationRefRange'] = "$($selectedLab.refLow)-$($selectedLab.refHigh)"
  # Generate value that can be normal, high, or low
  $valueVariance = Get-SecureRandomInt 3  # 0=normal, 1=high, 2=low
  $d['observationValue'] = switch ($valueVariance) {
    0 { [int]($selectedLab.refLow + (($selectedLab.refHigh - $selectedLab.refLow) * (Get-Random -Minimum 0.2 -Maximum 0.8))) }  # Normal
    1 { [int]($selectedLab.refHigh + (Get-Random -Minimum 5 -Maximum 25)) }  # High
    2 { [int]([Math]::Max(1, $selectedLab.refLow - (Get-Random -Minimum 3 -Maximum 15))) }  # Low
  }
  
  # Additional data for other message types
  # Appointment data with proper coded values for SIU messages
  $appointmentTypes = @(
    @{ code='CHECKUP'; display='Check-up' }
    @{ code='FOLLOWUP'; display='Follow-up' }
    @{ code='CONSULT'; display='Consultation' }
    @{ code='PROCEDURE'; display='Procedure' }
    @{ code='ROUTINE'; display='Routine Visit' }
  )
  $selectedApptType = $appointmentTypes[(Get-SecureRandomInt $appointmentTypes.Count)]
  $d['appointmentId'] = Get-SecureRandomString 8
  $d['appointmentFillerId'] = Get-SecureRandomString 10  # SCH-2 Filler Appointment ID
  $apptStart = $now.AddDays([int](Get-SecureRandomInt 30)+1)
  # Include timezone offset for enterprise compatibility (e.g., 20260225050600+0100)
  $tzOffset = [System.TimeZoneInfo]::Local.GetUtcOffset($apptStart)
  $tzSign = if ($tzOffset.TotalMinutes -ge 0) { '+' } else { '-' }
  $tzFormatted = '{0}{1:D2}{2:D2}' -f $tzSign, [Math]::Abs($tzOffset.Hours), [Math]::Abs($tzOffset.Minutes)
  $d['appointmentDateTime'] = $apptStart.ToString('yyyyMMddHHmmss') + $tzFormatted
  $d['appointmentDuration'] = @('15','30','45','60')[(Get-SecureRandomInt 4)]
  $d['appointmentEndDateTime'] = $apptStart.AddMinutes([int]$d['appointmentDuration']).ToString('yyyyMMddHHmmss') + $tzFormatted
  $d['appointmentTypeCode'] = $selectedApptType.code
  $d['appointmentTypeDisplay'] = $selectedApptType.display
  $d['appointmentStatusCode'] = 'BOOKED'
  $d['appointmentStatusDisplay'] = 'Booked'
  # Medication data with matched dose/units/route/form for RDE messages
  $medications = @(
    @{ code='LISIN10'; name='Lisinopril 10mg'; dose='10'; units='mg'; form='TAB'; route='PO'; routeDisplay='Oral' }
    @{ code='METF500'; name='Metformin 500mg'; dose='500'; units='mg'; form='TAB'; route='PO'; routeDisplay='Oral' }
    @{ code='OMEP20'; name='Omeprazole 20mg'; dose='20'; units='mg'; form='CAP'; route='PO'; routeDisplay='Oral' }
    @{ code='ATOR40'; name='Atorvastatin 40mg'; dose='40'; units='mg'; form='TAB'; route='PO'; routeDisplay='Oral' }
    @{ code='AMLO5'; name='Amlodipine 5mg'; dose='5'; units='mg'; form='TAB'; route='PO'; routeDisplay='Oral' }
    @{ code='CEFT1G'; name='Ceftriaxone 1g'; dose='1'; units='g'; form='INJ'; route='IV'; routeDisplay='Intravenous' }
  )
  $selectedMed = $medications[(Get-SecureRandomInt $medications.Count)]
  $d['medicationCode'] = $selectedMed.code
  $d['medicationName'] = $selectedMed.name
  $d['medicationDose'] = $selectedMed.dose
  $d['medicationUnits'] = $selectedMed.units
  $d['medicationForm'] = $selectedMed.form
  $d['medicationRoute'] = $selectedMed.route
  $d['medicationRouteDisplay'] = $selectedMed.routeDisplay
  # Frequency with proper coding
  $frequencies = @(
    @{ code='QD'; display='Once daily' }
    @{ code='BID'; display='Twice daily' }
    @{ code='TID'; display='Three times daily' }
    @{ code='QID'; display='Four times daily' }
    @{ code='Q8H'; display='Every 8 hours' }
    @{ code='Q12H'; display='Every 12 hours' }
  )
  $selectedFreq = $frequencies[(Get-SecureRandomInt $frequencies.Count)]
  $d['medicationFrequency'] = $selectedFreq.code
  $d['medicationFrequencyDisplay'] = $selectedFreq.display
  $d['medicationDuration'] = @('3','5','7','10','14','30')[(Get-SecureRandomInt 6)]
  $d['rxFillerNumber'] = 'RX' + (Get-SecureRandomString 6)
  
  # Vaccine data for VXU messages (CVX codes)
  $vaccines = @(
    @{ cvx='208'; name='COVID-19, mRNA, LNP-S, PF, 30 mcg/0.3 mL dose'; mvx='PFR'; manufacturer='Pfizer'; dose='0.3'; units='mL' }
    @{ cvx='207'; name='COVID-19, mRNA, LNP-S, PF, 100 mcg/0.5 mL dose'; mvx='MOD'; manufacturer='Moderna'; dose='0.5'; units='mL' }
    @{ cvx='141'; name='Influenza, seasonal, injectable'; mvx='SKB'; manufacturer='GlaxoSmithKline'; dose='0.5'; units='mL' }
    @{ cvx='33'; name='Pneumococcal polysaccharide PPV23'; mvx='MSD'; manufacturer='Merck'; dose='0.5'; units='mL' }
    @{ cvx='21'; name='Varicella'; mvx='MSD'; manufacturer='Merck'; dose='0.5'; units='mL' }
    @{ cvx='03'; name='MMR'; mvx='MSD'; manufacturer='Merck'; dose='0.5'; units='mL' }
    @{ cvx='115'; name='Tdap'; mvx='PMC'; manufacturer='Sanofi Pasteur'; dose='0.5'; units='mL' }
    @{ cvx='83'; name='Hepatitis A, ped/adol, 2 dose'; mvx='MSD'; manufacturer='Merck'; dose='0.5'; units='mL' }
  )
  $selectedVaccine = $vaccines[(Get-SecureRandomInt $vaccines.Count)]
  $d['vaccineCvx'] = $selectedVaccine.cvx
  $d['vaccineName'] = $selectedVaccine.name
  $d['vaccineMvx'] = $selectedVaccine.mvx
  $d['vaccineManufacturer'] = $selectedVaccine.manufacturer
  $d['vaccineDose'] = $selectedVaccine.dose
  $d['vaccineUnits'] = $selectedVaccine.units
  $d['vaccineLotNumber'] = 'LOT' + (Get-SecureRandomString 6)
  $d['vaccineExpiration'] = $now.AddYears(1).ToString('yyyyMMdd')
  
  # Financial transaction data for DFT messages
  $transactionTypes = @(
    @{ code='CG'; display='Charge' }
    @{ code='CD'; display='Credit' }
    @{ code='PY'; display='Payment' }
  )
  $d['transactionType'] = ($transactionTypes[(Get-SecureRandomInt $transactionTypes.Count)]).code
  $d['transactionAmount'] = @('150.00','275.50','450.00','89.99','325.00','1250.00')[(Get-SecureRandomInt 6)]
  $d['transactionId'] = 'TXN' + (Get-SecureRandomString 8)
  # Document types with proper CE format for TXA-2
  $documentTypes = @(
    @{ code='DS'; display='Discharge Summary' }
    @{ code='HP'; display='History and Physical' }
    @{ code='OP'; display='Operative Report' }
    @{ code='CN'; display='Consultation Note' }
    @{ code='PN'; display='Progress Note' }
    @{ code='CD'; display='Clinical Document' }
  )
  $selectedDocType = $documentTypes[(Get-SecureRandomInt $documentTypes.Count)]
  $d['documentTypeCode'] = $selectedDocType.code
  $d['documentTypeDisplay'] = $selectedDocType.display
  # Document status codes per HL70271: AU=Authenticated, DI=Dictated, DO=Documented, IN=Incomplete, LA=Legally Authenticated
  $documentStatuses = @(
    @{ code='AU'; display='Authenticated' }
    @{ code='LA'; display='Legally Authenticated' }
    @{ code='DI'; display='Dictated' }
    @{ code='IN'; display='Incomplete' }
  )
  $selectedDocStatus = $documentStatuses[(Get-SecureRandomInt $documentStatuses.Count)]
  $d['documentStatusCode'] = $selectedDocStatus.code
  $d['documentStatusDisplay'] = $selectedDocStatus.display
  # Generate unique document ID (separate from message control ID)
  $d['documentUniqueId'] = 'DOC' + (Get-SecureRandomString 8)
  $d['documentDateTime'] = $now.ToString('yyyyMMddHHmmss') + $tzFormatted
  $d['sendingApp'] = $inputSendingApp ?? 'XYOPS'
  $d['sendingFacility'] = $inputSendingFacility ?? 'HOSPITAL'
  $d['receivingApp'] = $inputReceivingApp ?? 'RECEIVER'
  $d['receivingFacility'] = $inputReceivingFacility ?? 'CLINIC'
  
  Write-XYProgress 0.5 'Building HL7 message...'
  
  $segments = [System.Collections.Generic.List[string]]::new()
  $segmentInfo = [System.Collections.Generic.List[object]]::new()
  
  # MSH - Message Header (always first)
  # Include timezone offset in MSH-7 for enterprise compatibility
  $mshTzOffset = [System.TimeZoneInfo]::Local.GetUtcOffset($now)
  $mshTzSign = if ($mshTzOffset.TotalMinutes -ge 0) { '+' } else { '-' }
  $mshTzFormatted = '{0}{1:D2}{2:D2}' -f $mshTzSign, [Math]::Abs($mshTzOffset.Hours), [Math]::Abs($mshTzOffset.Minutes)
  $mshTimestamp = $now.ToString('yyyyMMddHHmmss') + $mshTzFormatted
  # MSH-15: Accept Acknowledgment Type (AL=Always, NE=Never, ER=Error only)
  # MSH-16: Application Acknowledgment Type (AL=Always, NE=Never, ER=Error only)
  $msh = "MSH|^~\&|$($d.sendingApp)|$($d.sendingFacility)|$($d.receivingApp)|$($d.receivingFacility)|$mshTimestamp||$messageType^$eventType|$msgControlId|P|$version|||AL|AL"
  $segments.Add($msh)
  $segmentInfo.Add(@('MSH', 'Message Header', 'Identifies sender, receiver, message type, and version'))
  
  # EVN - Event Type (recommended for ADT messages per HL7 v2.5.1)
  if ($messageType -eq 'ADT') {
    # EVN-1: Event Type Code (deprecated in v2.5, use MSH-9.2)
    # EVN-2: Recorded Date/Time (required)
    # EVN-3: Date/Time Planned Event (optional)
    # EVN-4: Event Reason Code (optional)
    # EVN-5: Operator ID (optional)
    # EVN-6: Event Occurred (optional)
    $evn = "EVN|$eventType|$mshTimestamp"
    $segments.Add($evn)
    $segmentInfo.Add(@('EVN', 'Event Type', "Event: $eventType at $mshTimestamp"))
  }
  
  # PID - Patient Identification
  # PID field positions (v2.5.1):
  # PID-1: Set ID, PID-2: Patient ID (external, deprecated), PID-3: Patient Identifier List
  # PID-4: Alternate Patient ID (deprecated), PID-5: Patient Name, PID-6: Mother's Maiden Name
  # PID-7: Date/Time of Birth, PID-8: Administrative Sex
  if ($messageType -in @('ADT','ORM','ORU','SIU','RDE','MDM','DFT','VXU')) {
    $pidSeg = "PID|1||$($d.patientId)^^^$($d.sendingFacility)^MR||$($d.patientLastName)^$($d.patientFirstName)||$($d.patientDOB)|$($d.patientGender)"
    $segments.Add($pidSeg)
    $segmentInfo.Add(@('PID', 'Patient Identification', "Patient: $($d.patientFirstName) $($d.patientLastName), MRN: $($d.patientId)"))
  }
  
  # PV1 - Patient Visit
  # PV1 field positions (v2.5.1):
  # PV1-1: Set ID, PV1-2: Patient Class (I/O/E/P/R/B/C/N/U)
  # PV1-3: Assigned Patient Location (PL), PV1-4: Admission Type
  # PV1-5: Preadmit Number, PV1-6: Prior Patient Location
  # PV1-7: Attending Doctor (XCN), PV1-8: Referring Doctor
  # ...
  # PV1-19: Visit Number, PV1-44: Admit Date/Time, PV1-45: Discharge Date/Time
  if ($messageType -in @('ADT','ORM','ORU','SIU','RDE','DFT')) {
    # For SIU (scheduling), always default to Outpatient unless user explicitly set Inpatient or Emergency
    $pv1Class = if ($messageType -eq 'SIU') {
      if ($inputPatientClass -in @('I','E')) { $inputPatientClass } else { 'O' }
    } else { $d.patientClass }
    
    # Build PV1 with proper field positioning
    # PV1-7: Attending Doctor in XCN format (ID^Family^Given^Middle^Suffix^Prefix^Degree^Source)
    $attendingXcn = "$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)^^^DR"
    
    if ($messageType -eq 'ADT') {
      # For ADT, include visit number (PV1-19) and admit datetime (PV1-44)
      # PV1|1|class|location||||attending||||||||||||||visitNumber||||||||||||||||||||||||admitDateTime|dischargeDateTime
      # Using explicit field positions with proper separators
      $pv1 = "PV1|1|$pv1Class|$($d.assignedLocation)||||$attendingXcn||||||||||||$($d.visitNumber)|||||||||||||||||||||||$($d.admitDateTime)"
      if ($eventType -eq 'A03') {
        # A03 (discharge) - add discharge datetime in PV1-45
        $pv1 = "PV1|1|$pv1Class|$($d.assignedLocation)||||$attendingXcn||||||||||||$($d.visitNumber)|||||||||||||||||||||||$($d.admitDateTime)|$($d.dischargeDateTime)"
      }
    } else {
      $pv1 = "PV1|1|$pv1Class|$($d.assignedLocation)||||$attendingXcn"
    }
    $segments.Add($pv1)
    $segmentInfo.Add(@('PV1', 'Patient Visit', "Class: $pv1Class, Location: $($d.assignedLocation)"))
  }
  
  # Message-specific segments
  switch ($messageType) {
    'ADT' {
      # DG1 - Diagnosis (v2.5.1)
      # DG1-1: Set ID
      # DG1-2: Diagnosis Coding Method (deprecated)
      # DG1-3: Diagnosis Code (CE) - code^description^coding system
      # DG1-4: Diagnosis Description (deprecated, use DG1-3.2)
      # DG1-5: Diagnosis Date/Time
      # DG1-6: Diagnosis Type (A=Admitting, W=Working, F=Final)
      # DG1-7 through DG1-15: various optional fields
      # DG1-16: Diagnosing Clinician
      $diagType = switch ($eventType) {
        'A01' { 'A' }  # Admitting diagnosis
        'A03' { 'F' }  # Final diagnosis (discharge)
        'A04' { 'A' }  # Admitting diagnosis (registration)
        default { 'W' }  # Working diagnosis
      }
      $dg1 = "DG1|1||$($d.diagnosisCode)^$($d.diagnosisDescription)^I10||$mshTimestamp|$diagType||||||||||$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)"
      $segments.Add($dg1)
      $segmentInfo.Add(@('DG1', 'Diagnosis', "$($d.diagnosisCode) - $($d.diagnosisDescription) (Type: $diagType)"))
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
      # OBR: Set ID | Placer Order # | Filler Order # | Universal Service ID | Priority | Req DateTime | Observation DateTime | ... | Ordering Provider | ... | Result Status
      $obr = "OBR|1|$($d.orderNumber)||$($d.observationId)^$($d.observationName)^LN|||$($d.observationDateTime)||||||||$($d.orderingProviderId)^$($d.orderingProviderName)||||||||F"
      $segments.Add($obr)
      $segmentInfo.Add(@('OBR', 'Observation Request', "Test: $($d.observationId) - $($d.observationName)"))
      # OBX: Set ID | Value Type | Observation ID | Sub-ID | Value | Units | Ref Range | Abnormal Flags | ... | Status | ... | DateTime
      # Parse reference range to determine abnormal flag
      $refParts = $d.observationRefRange -split '-'
      [double]$refLow = $refParts[0]
      [double]$refHigh = $refParts[1]
      $abnormalFlag = if ([double]$d.observationValue -gt $refHigh) { 'H' } elseif ([double]$d.observationValue -lt $refLow) { 'L' } else { 'N' }
      $obx = "OBX|1|NM|$($d.observationId)^$($d.observationShortName)^LN||$($d.observationValue)|$($d.observationUnits)|$($d.observationRefRange)|$abnormalFlag|||$($d.observationStatus)|||$($d.observationDateTime)"
      $segments.Add($obx)
      $segmentInfo.Add(@('OBX', 'Observation Result', "Result: $($d.observationValue) $($d.observationUnits) (Ref: $($d.observationRefRange))"))
    }
    'SIU' {
      # SCH: Placer Appt ID | Filler Appt ID | Occurrence # | Placer Group # | Schedule ID | Event Reason | Appt Reason | Appt Type | Appt Duration | Duration Units | Appt Timing Qty | Placer Contact | ... | Filler Status
      # SCH-1: Placer Appointment ID, SCH-2: Filler Appointment ID
      # SCH-8: Appointment Type (CE) - code^display^coding system
      # SCH-11: Appointment Timing Quantity (TQ) - ^^^startDateTime^endDateTime
      # SCH-25: Filler Status Code (CE) - code^display^coding system
      $sch = "SCH|$($d.appointmentId)|$($d.appointmentFillerId)|||||$($d.appointmentTypeCode)^$($d.appointmentTypeDisplay)^HL70276|||^^^$($d.appointmentDateTime)^$($d.appointmentEndDateTime)||$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)||||$($d.appointmentStatusCode)^$($d.appointmentStatusDisplay)^HL70278"
      $segments.Add($sch)
      $segmentInfo.Add(@('SCH', 'Scheduling Activity', "Placer: $($d.appointmentId), Filler: $($d.appointmentFillerId)"))
      # AIS: Set ID | Segment Action | Universal Service ID | Start DateTime | Start Offset | Start Offset Units | Duration | Duration Units
      $ais = "AIS|1||$($d.appointmentTypeCode)^$($d.appointmentTypeDisplay)||$($d.appointmentDateTime)|$($d.appointmentDuration)|MIN"
      $segments.Add($ais)
      $segmentInfo.Add(@('AIS', 'Appointment Info', "Type: $($d.appointmentTypeDisplay), Duration: $($d.appointmentDuration) min"))
      # AIL: Set ID | Segment Action | Location Resource ID | Location Type | Location Group | Start DateTime | Start Offset | Start Offset Units | Duration | Duration Units | Allow Substitution | Filler Status
      # Models the location as a schedulable resource
      $ail = "AIL|1||$($d.assignedLocation)||||||$($d.appointmentDuration)|MIN||$($d.appointmentStatusCode)^$($d.appointmentStatusDisplay)^HL70278"
      $segments.Add($ail)
      $segmentInfo.Add(@('AIL', 'Appointment Location', "Location: $($d.assignedLocation)"))
      # AIP: Set ID | Segment Action | Personnel Resource ID | Resource Type | Resource Group | Start DateTime | Start Offset | Start Offset Units | Duration | Duration Units | Allow Substitution | Filler Status
      $aip = "AIP|1||$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)|||||$($d.appointmentStatusCode)^$($d.appointmentStatusDisplay)^HL70278"
      $segments.Add($aip)
      $segmentInfo.Add(@('AIP', 'Appointment Provider', "Provider: $($d.attendingFirstName) $($d.attendingLastName)"))
    }
    'RDE' {
      # ORC: Order Control | Placer Order # | Filler Order # | Placer Group # | Status | ... | DateTime | ... | Ordering Provider
      # ORC-5: IP=In Process (appropriate for new order NW), not CM=Completed
      $orc = "ORC|NW|$($d.orderNumber)||$($d.rxFillerNumber)|IP||||$mshTimestamp|$($d.orderingProviderId)^$($d.orderingProviderName)"
      $segments.Add($orc)
      $segmentInfo.Add(@('ORC', 'Common Order', "Placer: $($d.orderNumber), Status: In Process"))
      # RXE field positions (v2.5.1):
      # RXE-1: Quantity/Timing (deprecated, use TQ1)
      # RXE-2: Give Code (CE) - code^name^coding system
      # RXE-3: Give Amount - Minimum
      # RXE-4: Give Amount - Maximum (optional)
      # RXE-5: Give Units (CE)
      # RXE-6: Give Dosage Form (CE)
      # RXE-7: Provider's Administration Instructions
      # RXE-8: Deliver-To Location (deprecated)
      # RXE-9: Substitution Status
      # RXE-10: Dispense Amount
      # RXE-11: Dispense Units
      # RXE-12: Number of Refills
      # RXE-13: Ordering Provider's DEA Number
      # RXE-14: Pharmacist/Treatment Supplier's Verifier ID
      # RXE-15: Prescription Number
      # ... more fields ...
      # RXE-22: Give Per (Time Unit)
      # RXE-23: Give Rate Amount
      # RXE-24: Give Rate Units
      $rxe = "RXE||^$($d.medicationCode)^$($d.medicationName)^L|$($d.medicationDose)||$($d.medicationUnits)^$($d.medicationUnits)^ISO+|$($d.medicationForm)^$($d.medicationForm)^HL70292|^$($d.medicationFrequency)^$($d.medicationFrequencyDisplay)^HL70335"
      $segments.Add($rxe)
      $segmentInfo.Add(@('RXE', 'Pharmacy Encoded Order', "$($d.medicationName) $($d.medicationDose)$($d.medicationUnits) $($d.medicationFrequency)"))
      # RXR: Route (required for RDE)
      $rxr = "RXR|$($d.medicationRoute)^$($d.medicationRouteDisplay)^HL70162"
      $segments.Add($rxr)
      $segmentInfo.Add(@('RXR', 'Pharmacy Route', "Route: $($d.medicationRouteDisplay)"))
    }
    'MDM' {
      # TXA field positions (v2.5.1):
      # TXA-1: Set ID
      # TXA-2: Document Type (CE) - code^display^coding system (HL70270)
      # TXA-3: Document Content Presentation (ID) - TX=Text, FT=Formatted Text, etc.
      # TXA-4: Activity Date/Time
      # TXA-5: Primary Activity Provider Code
      # TXA-6: Origination Date/Time
      # TXA-7: Transcription Date/Time
      # TXA-8: Edit Date/Time
      # TXA-9: Originator Code/Name
      # TXA-10: Assigned Document Authenticator
      # TXA-11: Transcriptionist Code/Name
      # TXA-12: Unique Document Number (EI) - should be different from MSH-10
      # TXA-13: Parent Document Number
      # TXA-14: Placer Order Number
      # TXA-15: Filler Order Number
      # TXA-16: Unique Document File Name
      # TXA-17: Document Completion Status (ID) - HL70271
      $txa = "TXA|1|$($d.documentTypeCode)^$($d.documentTypeDisplay)^HL70270|TX|$($d.documentDateTime)||||||$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)||$($d.documentUniqueId)||||||$($d.documentStatusCode)"
      $segments.Add($txa)
      $segmentInfo.Add(@('TXA', 'Document Header', "Type: $($d.documentTypeDisplay), Doc ID: $($d.documentUniqueId), Status: $($d.documentStatusDisplay)"))
      # OBX for document content
      # OBX-3: Use proper document content identifier, not the document type code
      $obx = "OBX|1|TX|DOC^Document Text||Patient presents with $($d.admitReason). Assessment and plan documented.||||||F"
      $segments.Add($obx)
      $segmentInfo.Add(@('OBX', 'Document Content', 'Clinical note content'))
    }
    'DFT' {
      # DFT^P03 - Post Detail Financial Transaction
      # FT1 field positions (v2.5.1):
      # FT1-1: Set ID
      # FT1-2: Transaction ID
      # FT1-3: Transaction Batch ID
      # FT1-4: Transaction Date (required)
      # FT1-5: Transaction Posting Date
      # FT1-6: Transaction Type (CG=Charge, CD=Credit, PY=Payment)
      # FT1-7: Transaction Code (CE) - procedure/charge code
      # FT1-8: Transaction Description (deprecated)
      # FT1-9: Transaction Description - Alt
      # FT1-10: Transaction Quantity
      # FT1-11: Transaction Amount - Extended
      # FT1-12: Transaction Amount - Unit
      # FT1-13: Department Code
      # FT1-14: Insurance Plan ID
      # FT1-15: Insurance Amount
      # FT1-16: Assigned Patient Location
      # FT1-17: Fee Schedule
      # FT1-18: Patient Type
      # FT1-19: Diagnosis Code - FT1 (CE)
      # FT1-20: Performed By Code (XCN)
      # FT1-21: Ordered By Code
      # FT1-22: Unit Cost
      # FT1-23: Filler Order Number
      # FT1-24: Entered By Code
      # FT1-25: Procedure Code (CE)
      $ft1 = "FT1|1|$($d.transactionId)||$mshTimestamp|$mshTimestamp|CG|99213^Office visit, established patient, level 3^CPT||||$($d.transactionAmount)||||||$($d.patientClass)||$($d.diagnosisCode)^$($d.diagnosisDescription)^I10|$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)||||||||99213^Office visit, established patient, level 3^CPT"
      $segments.Add($ft1)
      $segmentInfo.Add(@('FT1', 'Financial Transaction', "TXN: $($d.transactionId), Amount: \$$($d.transactionAmount)"))
    }
    'VXU' {
      # VXU^V04 - Unsolicited Vaccination Record Update
      # Required structure: MSH, PID, [PD1], {[NK1]}, [PV1], [PV2], [{IN1, [IN2], [IN3]}], {ORC, [RXA, [RXR], {[OBX]}]}
      # ORC field positions (v2.5.1):
      # ORC-1: Order Control (RE=Observations/Performed Service to Follow)
      # ORC-2: Placer Order Number
      # ORC-3: Filler Order Number
      $orc = "ORC|RE|$($d.orderNumber)|$($d.orderNumber)^$($d.sendingFacility)"
      $segments.Add($orc)
      $segmentInfo.Add(@('ORC', 'Common Order', "Order: $($d.orderNumber)"))
      # RXA field positions (v2.5.1):
      # RXA-1: Give Sub-ID Counter (0 for historical, 1+ for administered)
      # RXA-2: Administration Sub-ID Counter
      # RXA-3: Date/Time Start of Administration (required)
      # RXA-4: Date/Time End of Administration (required)
      # RXA-5: Administered Code (CE) - CVX code^name^CVX
      # RXA-6: Administered Amount (required)
      # RXA-7: Administered Units (CE)
      # RXA-8: Administered Dosage Form
      # RXA-9: Administration Notes (CE)
      # RXA-10: Administering Provider (XCN)
      # RXA-11: Administered-at Location
      # RXA-12: Administered Per (Time Unit)
      # RXA-13: Administered Strength
      # RXA-14: Administered Strength Units
      # RXA-15: Substance Lot Number
      # RXA-16: Substance Expiration Date
      # RXA-17: Substance Manufacturer Name (CE) - MVX code
      # RXA-18: Substance/Treatment Refusal Reason
      # RXA-19: Indication
      # RXA-20: Completion Status (CP=Complete, RE=Refused, NA=Not Administered, PA=Partially Administered)
      # RXA-21: Action Code - RXA (A=Add, D=Delete, U=Update)
      $rxa = "RXA|0|1|$mshTimestamp|$mshTimestamp|$($d.vaccineCvx)^$($d.vaccineName)^CVX|$($d.vaccineDose)|$($d.vaccineUnits)^$($d.vaccineUnits)^UCUM||00^New immunization record^NIP001|$($d.attendingId)^$($d.attendingLastName)^$($d.attendingFirstName)||||$($d.vaccineLotNumber)|$($d.vaccineExpiration)|$($d.vaccineMvx)^$($d.vaccineManufacturer)^MVX|||CP|A"
      $segments.Add($rxa)
      $segmentInfo.Add(@('RXA', 'Vaccine Administration', "$($d.vaccineName) ($($d.vaccineDose) $($d.vaccineUnits))"))
      # RXR - Pharmacy/Treatment Route (recommended for vaccines)
      # RXR-1: Route (CE) - HL70162
      # RXR-2: Administration Site (CWE) - HL70163
      $rxr = "RXR|IM^Intramuscular^HL70162|LA^Left Arm^HL70163"
      $segments.Add($rxr)
      $segmentInfo.Add(@('RXR', 'Pharmacy Route', 'Route: Intramuscular, Site: Left Arm'))
      # OBX - Observation/Result (for vaccine eligibility, VIS dates, etc.)
      # OBX-1: Set ID
      # OBX-2: Value Type (CE=Coded Entry, DT=Date, NM=Numeric, etc.)
      # OBX-3: Observation Identifier (CE)
      # OBX-4: Observation Sub-ID
      # OBX-5: Observation Value
      # OBX-11: Observation Result Status (F=Final)
      $obx = "OBX|1|CE|64994-7^Vaccine funding program eligibility category^LN||V02^VFC eligible - Medicaid/Medicaid Managed Care^HL70064||||||F"
      $segments.Add($obx)
      $segmentInfo.Add(@('OBX', 'Observation', 'Vaccine funding eligibility'))
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
    # Check if JobInput exists and has data
    # JobInput can be null, empty hashtable, or PSObject - need to handle all cases
    $hasInputData = $false
    $inputData = $null
    
    if ($null -ne $JobInput) {
      if ($JobInput -is [hashtable]) {
        if ($JobInput.ContainsKey('data') -and $null -ne $JobInput['data']) {
          $inputData = $JobInput['data']
          $hasInputData = $true
        }
      } elseif ($null -ne $JobInput.PSObject -and $null -ne $JobInput.PSObject.Properties -and ($JobInput.PSObject.Properties.Name -contains 'data')) {
        $inputData = $JobInput.data
        $hasInputData = ($null -ne $inputData)
      }
    }
    
    if (-not $hasInputData) {
      throw 'Bucket data source selected but no input data available from previous job. Please run a job that outputs data to the bucket first, or select a different data source (text field or file).'
    }
    $path = (Get-Param $Params 'hl7ParserDataPath' '')
    $val = if ($path.Trim()) { Get-NestedValue $inputData $path } else { $inputData }
    if ($null -eq $val) { throw "Data path '$path' not found in bucket data" }
    # Handle if bucket contains the message directly or in a 'message' field
    if ($val -is [PSCustomObject] -or $val -is [hashtable]) {
      # Try common field names using safe property access
      $hl7Input = ''
      foreach ($fieldName in @('message', 'hl7Message', 'hl7', 'content', 'data')) {
        $hasField = if ($val -is [hashtable]) { $val.ContainsKey($fieldName) } else { $val.PSObject.Properties.Name -contains $fieldName }
        if ($hasField) {
          $fieldVal = $val.$fieldName
          if ($fieldVal -and "$fieldVal".Trim()) {
            $hl7Input = "$fieldVal"
            break
          }
        }
      }
      if (-not $hl7Input) { throw "Bucket data is an object but no 'message', 'hl7Message', 'hl7', 'content', or 'data' field found containing the HL7 message" }
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
  $tool = if ($null -ne $params.PSObject -and $params.PSObject.Properties.Name -contains 'tool') { $params.tool } else { 'hl7Generator' }
  $cwd = if ($null -ne $job.PSObject -and $job.PSObject.Properties.Name -contains 'cwd') { [string]$job.cwd } else { (Get-Location).Path }
  $jobInput = if ($null -ne $job.PSObject -and $job.PSObject.Properties.Name -contains 'input') { $job.input } else { @{} }

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
