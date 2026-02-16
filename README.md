# xyOps Healthcare Plugin

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/talder/xyOps-healthcare/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue.svg)](https://github.com/PowerShell/PowerShell)

An xyOps Event Plugin for healthcare interoperability, providing HL7 v2.5.1 message generation and parsing tools.

## Disclaimer

**USE AT YOUR OWN RISK.** This software is provided "as is", without warranty of any kind, express or implied. The author and contributors are not responsible for any damages, data loss, or other issues that may arise from the use of this software. Always test in non-production environments first.

---

## HL7 Version

This plugin generates and parses **HL7 v2.5.1** compliant messages. All messages follow strict HL7 v2.5.1 specifications including:

- Proper segment structure and field ordering
- Correct data types (CE, XCN, PL, TS, etc.)
- Standard coding systems (ICD-10, CVX, MVX, CPT, LOINC, HL7 tables)
- Timezone-aware timestamps (e.g., `20260216052926+0100`)
- Required and recommended segments per message type

## Tools

| Tool | Description |
|------|-------------|
| HL7 Message Generator | Generate valid HL7 v2.5.1 messages with fake or custom data |
| HL7 Message Parser | Parse, analyze, and validate HL7 v2.5.1 messages |

## Installation

### Manual Installation

```bash
cd /opt/xyops/plugins
git clone https://github.com/talder/xyOps-healthcare.git
```

## HL7 Message Generator

Generate valid HL7 v2.5.1 messages for testing healthcare integrations.

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

| Type | Name | Segments | Description |
|------|------|----------|-------------|
| ADT | Admit/Discharge/Transfer | MSH, EVN, PID, PV1, DG1 | Patient administration events |
| ORM | Order Message | MSH, PID, PV1, ORC, OBR | Lab and radiology orders |
| ORU | Observation Result | MSH, PID, PV1, OBR, OBX | Lab results with LOINC codes |
| SIU | Scheduling | MSH, PID, PV1, SCH, AIS, AIL, AIP | Appointments with resources |
| RDE | Pharmacy Order | MSH, PID, PV1, ORC, RXE, RXR | Medication orders |
| MDM | Medical Document | MSH, PID, TXA, OBX | Clinical documents |
| DFT | Financial Transaction | MSH, PID, PV1, FT1 | Billing with CPT codes |
| VXU | Vaccination Update | MSH, PID, ORC, RXA, RXR, OBX | Immunizations with CVX/MVX codes |

### ADT Event Types

| Event | Description | Diagnosis Type |
|-------|-------------|----------------|
| A01 | Admit/Visit Notification | A (Admitting) |
| A02 | Transfer a Patient | W (Working) |
| A03 | Discharge/End Visit | F (Final) |
| A04 | Register a Patient | A (Admitting) |
| A05 | Pre-admit a Patient | W (Working) |
| A08 | Update Patient Information | W (Working) |
| A11 | Cancel Admit | W (Working) |
| A13 | Cancel Discharge | W (Working) |
| A28 | Add Person Information | W (Working) |
| A31 | Update Person Information | W (Working) |

### Message Type Details

#### ADT (Admit/Discharge/Transfer)
- **EVN**: Event type segment with recorded timestamp
- **PV1**: Patient visit with attending physician (XCN format), visit number, admit/discharge timestamps
- **DG1**: Diagnosis with ICD-10 coding (I10), diagnosing clinician, context-appropriate diagnosis type

#### ORU (Observation Result)
- **OBR**: Observation request with LOINC-coded tests
- **OBX**: Results with reference ranges, abnormal flags (H/L/N), units

#### SIU (Scheduling)
- **SCH**: Placer and filler appointment IDs, appointment type (HL70276), timing, filler status (HL70278)
- **AIS**: Appointment information service
- **AIL**: Location resource with duration
- **AIP**: Provider resource

#### RDE (Pharmacy Order)
- **ORC**: Order control with status (IP=In Process for new orders)
- **RXE**: Proper field positions - RXE-3 (dose), RXE-4 (max, empty), RXE-5 (units as CE), RXE-6 (form)
- **RXR**: Route with HL70162 coding

#### MDM (Medical Document)
- **TXA**: Document type (HL70270), unique document ID (separate from message control ID), completion status (HL70271)
- **OBX**: Document content with proper identifier

#### DFT (Financial Transaction)
- **FT1**: Transaction ID, CPT procedure codes, transaction amount, diagnosis (ICD-10), performing provider

#### VXU (Vaccination Update)
- **ORC**: Order with filler order number
- **RXA**: CVX vaccine codes, dose amount/units (UCUM), lot number, expiration, manufacturer (MVX), completion status
- **RXR**: Route (IM) and administration site (HL70163)
- **OBX**: Vaccine funding eligibility (LOINC-coded)

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

### Example HL7 v2.5.1 Message (ADT^A01)

```
MSH|^~\&|XYOPS|HOSPITAL|RECEIVER|CLINIC|20260216052647+0100||ADT^A01|NSARQN2S8P|P|2.5.1|||AL|AL
EVN|A01|20260216052647+0100
PID|1||VOAWYSEF^^^HOSPITAL^MR||Miller^Michael||19730213|M
PV1|1|O|ROOM422^BED2^FLOOR1||||TSTOO8^Brown^Michael^^^DR||||||||||||G9M8X4UYIS|||||||||||||||||||||||202602160526
DG1|1||S82.90XA^Unspecified fracture of lower leg, initial encounter^I10||20260216052647+0100|A||||||||||TSTOO8^Brown^Michael
```

## HL7 Message Parser

Parse and validate HL7 v2.5.1 messages from text, files, or bucket data.

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

**Tim Alderweireldt (c)2026**
