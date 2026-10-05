# productivity_tracker
lets test

A new Flutter project.
login details 
Role	        Email	                   Password	         
dpl_dispatch	                dispatch@vistarlogitek.com	 
dpl_qa	                        qa@vistarlogitek.com	    ChangeMe@123	
dpl_pdi	                        pdi@vistarlogitek.com	    ChangeMe@123	
Role	                        Email	                        Password	Role string
Security (origin plant gate)	security@vistarlogitek.com	ChangeMe@123	dpl_security
QRE (TATA quality)	            qre.tata@vistarlogitek.com	ChangeMe@123	dpl_qre
Driver	                        driver1@vistarlogitek.com	ChangeMe@123	dpl_driver


A "bucket" = one unique (organization, machine, part)
## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Usage analytics (event tracker)

`lib/core/telemetry/telemetry.dart`, using the in-house `vistar_event_tracker`
SDK (vendored in `packages/`, see its `VENDORED.md`). Read in the Platform
Console under Analytics > Event tracker.

Off unless the build gets both `ET_APP_ID` and `ET_WRITE_KEY` (Cloudflare
build variables; `cloudflare-build.sh` passes them on). For an APK:
`flutter build apk --dart-define=ET_APP_ID=dpl_app --dart-define=ET_WRITE_KEY=wk_...`.
Optional `ET_BASE_URL` sends a test build's events elsewhere (UAT, local).
Register the app and get its write key in the Platform Console, Settings >
Event tracker (the key only allows adding events).

Sent: screen views by route pattern (ids replaced), sign-in / sign-out (the
user as `dpl:<id>` with role and organisation code), named actions from
successful API writes (`plan_created`, `item_started`, `label_printed`,
`pallet_closed`, `trip_created`, `dispatch_slip_created`, `slip_pdi_approved`,
... see `_actions`), failed API calls (5xx / no connection) and client errors.
Never sent: request or response bodies, names, emails, part numbers,
quantities. Events are queued offline and sent in batches.
