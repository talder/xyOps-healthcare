<p align="center"><img src="https://raw.githubusercontent.com/talder/xyOps-healthcare/refs/heads/main/logo.png" height="108" alt="Logo"/></p>
<h1 align="center">xyOps Healthcare</h1>

# xyOps Healthcare Plugin

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/talder/xyOps-healthcare/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows%20%7C%20macOS-lightgrey.svg)]()

An xyOps Event Plugin for healthcare interoperability, providing HL7 v2.5.1 message generation and parsing tools.

## Disclaimer

**USE AT YOUR OWN RISK.** This software is provided "as is", without warranty of any kind, express or implied. The author and contributors are not responsible for any damages, data loss, or other issues that may arise from the use of this software. Always test in non-production environments first.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Installation](#installation)
- [HL7 Version](#hl7-version)
- [Tools Overview](#tools-overview)
- [HL7 Message Generator](#hl7-message-generator)
- [HL7 Message Parser](#hl7-message-parser)
- [Bucket Data (Job Input)](#bucket-data-job-input)
- [Output Data Reference](#output-data-reference)
- [Dependencies](#dependencies)
- [License](#license)
- [Version History](#version-history)

---

## Quick Start

1. Install the plugin in xyOps (copy to plugins directory or install from Marketplace)
2. Add the Healthcare event to any job
3. Select HL7 Generator or HL7 Parser
4. Configure message type and parameters
5. Run the job

---

## Installation

### From xyOps Marketplace

1. Navigate to xyOps Marketplace
2. Search for "Healthcare"
3. Click Install

### Manual Installation

```bash
cd /opt/xyops/plugins
git clone https://github.com/talder/xyOps-healthcare.git
```

---

## HL7 Version

This plugin generates and parses **HL7 v2.5.1** compliant messages. All messages follow strict HL7 v2.5.1 specifications including:

- Proper segment structure and field ordering
- Correct data types (CE, XCN, PL, TS, etc.)
- Standard coding systems (ICD-10, CVX, MVX, CPT, LOINC, HL7 tables)
- Timezone-aware timestamps (e.g., `20260216052926+0100`)
- Required and recommended segments per message type

---

## Tools Overview

| Tool | Description |
|------|-------------|
| **HL7 Message Generator** | Generate valid HL7 v2.5.1 messages with fake or custom data |
| **HL7 Message Parser** | Parse, analyze, and validate HL7 v2.5.1 messages |

---

## HL7 Message Generator

Generate valid HL7 v2.5.1 messages for testing healthcare integrations.

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| Data Source | Select | form | Source of patient/message data |
| Data Path | Text | - | Dot-notation path to data in bucket |
| Message Type | Select | ADT | Type of HL7 message to generate |
| Event Type | Select | A01 | Event type (for ADT messages) |

### Data Sources

| Source | Description |
|--------|-------------|
| Form fields only | Use form fields (empty fields generate random data) |
| Bucket data | Load from bucket, form fields override bucket values |

**Priority:** Form fields > Bucket data > Random fake data

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

### Patient Demographics (PID segment)

| Field | Format | Description |
|-------|--------|-------------|
| `patientId` | Text | Medical Record Number (MRN) |
| `patientFirstName` | Text | Patient first name |
| `patientMiddleName` | Text | Patient middle name |
| `patientLastName` | Text | Patient last name |
| `patientDOB` | YYYYMMDD | Date of birth (e.g., 19850315) |
| `patientGender` | M/F/O/U | Male, Female, Other, Unknown |
| `patientSSN` | 123-45-6789 | Social Security Number |
| `patientRace` | Code | CDC race code (e.g., 2106-3=White) |
| `patientMaritalStatus` | S/M/D/W | Single, Married, Divorced, Widowed |
| `patientAddress` | Text | Street address |
| `patientCity` | Text | City |
| `patientState` | XX | Two-letter state code (e.g., NY) |
| `patientZip` | Text | ZIP code |
| `patientPhone` | Text | Phone number |

### Visit Information (PV1 segment)

| Field | Format | Description |
|-------|--------|-------------|
| `attendingId` | Text | Attending physician ID |
| `attendingFirstName` | Text | Attending physician first name |
| `attendingLastName` | Text | Attending physician last name |
| `visitNumber` | Text | Visit/encounter number |
| `patientClass` | I/O/E/P | Inpatient, Outpatient, Emergency, Preadmit |
| `assignedLocation` | ROOM^BED^FLOOR | Patient location |
| `admitDateTime` | YYYYMMDDHHmm | Admit date/time |
| `dischargeDateTime` | YYYYMMDDHHmm | Discharge date/time (for A03) |
| `admitReason` | Text | Reason for admission |

### Diagnosis (DG1 segment)

| Field | Format | Description |
|-------|--------|-------------|
| `diagnosisCode` | Text | ICD-10 diagnosis code |
| `diagnosisDescription` | Text | Diagnosis description |

### Message Header (MSH segment)

| Field | Format | Description |
|-------|--------|-------------|
| `sendingApp` | Text | Sending application name (default: XYOPS) |
| `sendingFacility` | Text | Sending facility name |
| `receivingApp` | Text | Receiving application name |
| `receivingFacility` | Text | Receiving facility name |

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
DG1|1||S82.90XA^Unspecified fracture of lower leg^I10||20260216052647+0100|A||||||||||TSTOO8^Brown^Michael
```

---

## HL7 Message Parser

Parse and validate HL7 v2.5.1 messages from text, files, or bucket data.

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| Data Source | Select | text | Source of HL7 message |
| HL7 Message | Textarea | - | Paste HL7 message directly |
| File Path | Text | - | Path to .hl7 file |
| Data Path | Text | - | Dot-notation path to HL7 in bucket |

### Data Sources

| Source | Description |
|--------|-------------|
| Text field | Paste HL7 message directly into the text area |
| File | Load from a .hl7 file on disk |
| Bucket data | Read HL7 message from previous job's bucket data |

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
  "segments": ["MSH", "EVN", "PID", "PV1", "DG1"],
  "errors": [],
  "warnings": []
}
```

---

## Bucket Data (Job Input)

### Data Path Notation

The data path uses dot-notation to navigate nested objects:
- `hl7Message` → `data.hl7Message`
- `patient.hl7` → `data.patient.hl7`

### Bucket Data Template

Copy and paste this template into your bucket:

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

---

## Output Data Reference

| Tool | Key Output Fields |
|------|-------------------|
| HL7 Generator | `data.message`, `data.file`, `data.segments`, `data.controlId` |
| HL7 Parser | `data.segments`, `data.valid`, `data.errors`, `data.warnings` |

---

## Dependencies

- PowerShell 7.0 or higher
- No external dependencies

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Version History

### v1.0.0 (2026-02-15)
- Initial release
- Split from xyOps Toolbox plugin
- HL7 v2.5.1 Message Generator
- HL7 v2.5.1 Message Parser

---

## Copyright

(c) 2026 Tim Alderweireldt
