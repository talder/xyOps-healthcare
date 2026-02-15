# xyOps Healthcare Plugin

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/talder/xyOps-healthcare/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue.svg)](https://github.com/PowerShell/PowerShell)

An xyOps Event Plugin for healthcare interoperability, providing HL7 v2.x message generation and parsing tools.

## Tools

| Tool | Description |
|------|-------------|
| HL7 Message Generator | Generate valid HL7 v2.x messages with fake or custom data |
| HL7 Message Parser | Parse, analyze, and validate HL7 v2.x messages |

## Installation

### Manual Installation

```bash
cd /opt/xyops/plugins
git clone https://github.com/talder/xyOps-healthcare.git
```

## HL7 Message Generator

Generate valid HL7 v2.x messages for testing healthcare integrations.

### Data Sources

The HL7 Generator supports two data sources:

| Source | Description |
|--------|-------------|
| Form fields only | Use only the form fields below (empty fields generate random data) |
| Bucket data | Load data from a bucket, form fields override bucket values |

**Priority:** Form fields > Bucket data > Random fake data

### Using Bucket Data

1. Create a bucket with your patient/HL7 data
2. Select "Use bucket data" as the Data Source
3. Optionally specify a data path prefix (e.g., `hl7` to read from `data.hl7.*`)
4. Override specific fields using the form fields if needed

### Bucket Data Template

Copy and paste this template into your bucket and fill in the values you need:

```json
{
  "patientId": "MRN123456",
  "patientFirstName": "John",
  "patientMiddleName": "Robert",
  "patientLastName": "Smith",
  "patientDOB": "19850315",
  "patientGender": "M",
  "patientSSN": "123-45-6789",
  "patientRace": "2106-3",
  "patientMaritalStatus": "M",
  "patientAddress": "123 Main Street",
  "patientCity": "New York",
  "patientState": "NY",
  "patientZip": "10001",
  "patientPhone": "(555)123-4567",
  "attendingId": "DOC001",
  "attendingFirstName": "Mary",
  "attendingLastName": "Johnson",
  "visitNumber": "VN12345678",
  "patientClass": "I",
  "assignedLocation": "ROOM101^BED1^FLOOR1",
  "admitDateTime": "202601151030",
  "dischargeDateTime": "202601201400",
  "admitReason": "Chest pain",
  "diagnosisCode": "J18.9",
  "diagnosisDescription": "Pneumonia, unspecified organism",
  "sendingApp": "XYOPS",
  "sendingFacility": "GENERAL_HOSPITAL",
  "receivingApp": "RECEIVER",
  "receivingFacility": "LAB_SYSTEM"
}
```

**Note:** All fields are optional. Empty or missing fields will generate random fake data.

### Supported Bucket Fields

**Patient Demographics (PID segment)**

| Field | Format | Description |
|-------|--------|-------------|
| `patientId` | Text | Medical Record Number (MRN) |
| `patientFirstName` | Text | Patient first name |
| `patientMiddleName` | Text | Patient middle name |
| `patientLastName` | Text | Patient last name |
| `patientDOB` | YYYYMMDD | Date of birth (e.g., 19850315) |
| `patientGender` | M/F/O/U | Male, Female, Other, Unknown |
| `patientSSN` | 123-45-6789 | Social Security Number |
| `patientRace` | Code | CDC race code (e.g., 2106-3=White, 2054-5=Black) |
| `patientMaritalStatus` | S/M/D/W | Single, Married, Divorced, Widowed |
| `patientAddress` | Text | Street address |
| `patientCity` | Text | City |
| `patientState` | XX | Two-letter state code (e.g., NY, CA) |
| `patientZip` | Text | ZIP code |
| `patientPhone` | Text | Phone number |

**Visit Information (PV1 segment)**

| Field | Format | Description |
|-------|--------|-------------|
| `attendingId` | Text | Attending physician ID |
| `attendingFirstName` | Text | Attending physician first name |
| `attendingLastName` | Text | Attending physician last name |
| `visitNumber` | Text | Visit/encounter number |
| `patientClass` | I/O/E/P | Inpatient, Outpatient, Emergency, Preadmit |
| `assignedLocation` | ROOM^BED^FLOOR | Patient location (e.g., ROOM101^BED1^FLOOR1) |
| `admitDateTime` | YYYYMMDDHHmm | Admit date/time (e.g., 202601151030) |
| `dischargeDateTime` | YYYYMMDDHHmm | Discharge date/time (for A03 events) |
| `admitReason` | Text | Reason for admission |

**Diagnosis (DG1 segment)**

| Field | Format | Description |
|-------|--------|-------------|
| `diagnosisCode` | Text | ICD-10 diagnosis code |
| `diagnosisDescription` | Text | Diagnosis description |

**Message Header (MSH segment)**

| Field | Format | Description |
|-------|--------|-------------|
| `sendingApp` | Text | Sending application name (default: XYOPS) |
| `sendingFacility` | Text | Sending facility name |
| `receivingApp` | Text | Receiving application name (default: RECEIVER) |
| `receivingFacility` | Text | Receiving facility name |

### Supported Message Types

| Type | Name | Description |
|------|------|-------------|
| ADT | Admit/Discharge/Transfer | Patient administration events |
| ORM | Order Message | Lab and radiology orders |
| ORU | Observation Result | Lab results |
| SIU | Scheduling | Appointments |
| RDE | Pharmacy Order | Medication orders |
| MDM | Medical Document | Clinical documents |
| DFT | Financial Transaction | Billing |
| VXU | Vaccination Update | Immunizations |

### ADT Event Types

| Event | Description |
|-------|-------------|
| A01 | Admit/Visit Notification |
| A02 | Transfer a Patient |
| A03 | Discharge/End Visit |
| A04 | Register a Patient |
| A05 | Pre-admit a Patient |
| A08 | Update Patient Information |
| A11 | Cancel Admit |
| A13 | Cancel Discharge |
| A28 | Add Person Information |
| A31 | Update Person Information |

### Example Output

```json
{
  "tool": "HL7 Generator",
  "messageType": "ADT",
  "eventType": "A01",
  "version": "2.5.1",
  "controlId": "ABC123XYZ",
  "file": "hl7-ADT-A01-ABC123XYZ.hl7"
}
```

## HL7 Message Parser

Parse and validate HL7 v2.x messages from text, files, or bucket data.

### Data Sources

| Source | Description |
|--------|-------------|
| Text field | Paste HL7 message directly into the text area |
| File | Load from a .hl7 file on disk |
| Bucket data | Read HL7 message from previous job's bucket data |

### Using Bucket Data

1. Run a previous job that outputs an HL7 message to the bucket
2. Select "Use bucket data" as the Data Source
3. Optionally specify a data path (e.g., `hl7Message` to read from `data.hl7Message`)

The parser will automatically detect the message from these bucket fields:
- Direct string value at path
- `message`, `hl7Message`, `hl7`, `content`, or `data` field within an object

### Validation Checks

| Check | Type | Description |
|-------|------|-------------|
| MSH segment | Required | Must be first segment |
| MSH-9 | Required | Message type must be present |
| MSH-10 | Required | Control ID must be present |
| MSH-12 | Warning | Version ID recommended |
| PID segment | Warning | Patient identification recommended |

### Example Output

```json
{
  "tool": "HL7 Parser",
  "messageType": "ADT",
  "eventType": "A01",
  "version": "2.5.1",
  "controlId": "ABC123XYZ",
  "valid": true,
  "segments": [...],
  "errors": [],
  "warnings": []
}
```

## Output Data Reference

| Tool | Key Output Fields |
|------|-------------------|
| HL7 Generator | `data.message`, `data.file`, `data.segments` |
| HL7 Parser | `data.segments`, `data.valid`, `data.errors` |

## Dependencies

This plugin uses PowerShell 7+ and has no external dependencies.

## License

This project is licensed under the MIT License.

## Author

**Tim Alderweireldt**
- Year: 2026
