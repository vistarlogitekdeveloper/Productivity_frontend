# Daily Production Loading (DPL) Module

> Manager-side UI for the DPL backend. **Phase 1 only** — the supervisor
> experience is stubbed with a "coming soon" placeholder.

## Folder layout

```
lib/features/dpl/
├── core/
│   ├── dpl_api_client.dart         # Dio instance bound to /api/v1/dpl
│   ├── dpl_api_response.dart       # { success, data, error, code } envelope
│   ├── dpl_api_service.dart        # All 38 endpoint wrappers
│   ├── dpl_constants.dart          # Path + status enums
│   └── dpl_error_mapper.dart       # Dio errors → DplApiResponse.error
├── models/                         # DplMachine, DplPart, DplProductionPlan, ...
├── manager/
│   ├── manager_shell.dart          # Bottom-nav scaffold (4 tabs)
│   ├── providers/                  # Riverpod providers per feature
│   ├── screens/
│   │   ├── dashboard_screen.dart
│   │   ├── upload_plan_screen.dart
│   │   ├── plan_list_screen.dart
│   │   ├── plan_detail_screen.dart
│   │   ├── reports_screen.dart
│   │   ├── masters_hub_screen.dart
│   │   └── masters/                # machines / parts / downtime reasons
│   └── widgets/                    # Reusable: status badge, machine card, ...
└── supervisor/
    └── supervisor_placeholder_screen.dart   # Phase 2 stub
```

## How DPL plugs into the existing app

| Concern | What we reused (zero changes) | What we added |
|---|---|---|
| Login screen | `lib/features/auth/login_screen.dart` | nothing |
| JWT storage | `LocalStorageRepository.getToken()` | nothing |
| Theme | `AppTheme.lightTheme` / `darkTheme` | nothing |
| Routing | `appRouterProvider` (go_router) | new DPL routes + role guards (additive) |
| Roles | `AppConstants.normalizeRole(...)` | `roleDplManager`, `roleDplSupervisor`, `isDplManagerRole`, etc. |
| Existing dashboards | Admin / Brin / Operator | untouched |
| HTTP | Shared `Dio` interceptor pattern | separate `dplDioProvider` bound to `dplApiBaseUrl` that reads the same JWT |
| Loading shimmer | `AppShimmer`, `SkeletonBox`, `SkeletonList` | reused as-is |
| File download | `saveReportBytes` (existing reports infra) | reused for report export |

## State management

Riverpod (matches the rest of the app). DPL providers are declared with the
hand-written `Provider` / `NotifierProvider` / `FutureProvider` / `AsyncNotifierProvider`
APIs — **no codegen** — so the module compiles without re-running
`build_runner`.

Top-level providers:

| Provider | Purpose |
|---|---|
| `dplDioProvider` | Dio bound to `https://.../api/v1/dpl` with the JWT interceptor |
| `dplApiServiceProvider` | `DplApiService` — every backend call lives here |
| `dplDashboardDateProvider` | Currently-selected dashboard date |
| `dplDashboardSummaryProvider` | `GET /manager/dashboard?date=` |
| `dplAlertsProvider` | `GET /manager/alerts` — polled every 60 s |
| `dplPlanListFiltersProvider`, `dplPlanListProvider` | `GET /manager/plans` + filter state |
| `dplPlanDetailProvider(id)` | `GET /manager/plans/:id` |
| `dplUploadPlanControllerProvider` | Upload form state (date, supervisor, mode, Excel preview, manual drafts) |
| `dplMachinesProvider`, `dplSupervisorsProvider`, `dplDowntimeReasonsProvider` | Master lists |
| `dplPartsControllerProvider`, `dplPartsSearchProvider` | Paginated parts master + autocomplete |
| `dplReportRangeProvider`, `dplPlanVsActualReportProvider`, `dplDowntimeReportProvider`, `dplSupervisorPerformanceReportProvider`, `dplPartWiseReportProvider` | Reports + shared from/to range |

## Navigating to DPL flows

| Route | Screen |
|---|---|
| `/dpl/manager` | `DplManagerShell` (Dashboard / Plans / Reports / Settings) |
| `/dpl/manager/upload-plan` | `DplUploadPlanScreen` |
| `/dpl/manager/plans/:id` | `DplPlanDetailScreen` |
| `/dpl/manager/masters/machines` | `DplMachinesMasterScreen` |
| `/dpl/manager/masters/parts` | `DplPartsMasterScreen` |
| `/dpl/manager/masters/downtime-reasons` | `DplDowntimeReasonsMasterScreen` |
| `/dpl/supervisor` | Phase-2 placeholder |

The router redirect lands a user with `role == DPL_MANAGER` on
`/dpl/manager` after login, and `DPL_SUPERVISOR` on `/dpl/supervisor`.
Non-DPL roles continue to land on their existing dashboards
(admin / brin / operator) — completely untouched.

## Backend conventions

- All paths relative to `AppConstants.dplApiBaseUrl`
  (`https://api.vistarlogitek.com/api/v1/dpl`).
- All authenticated requests carry `Authorization: Bearer <jwt>` — the
  JWT is the same one written by the existing login flow.
- All responses are unwrapped from `{ success, data, error, code }` by
  `DplApiService._send`. Raw shapes (lists/objects without envelope) are
  also tolerated.
- 401 → auto-logout (see `dplDioProvider`).

## Added packages

Only one new dependency was added to `pubspec.yaml`:

```yaml
file_picker: ^8.1.4   # Excel picker on the Upload Plan screen
```

Everything else (`dio`, `flutter_riverpod`, `go_router`, `fl_chart`,
`intl`, `excel`, `pdf`, `share_plus`, `shared_preferences`) was already
present.

After pulling the changes run:

```bash
flutter pub get
```

Then `flutter run` as usual.

## Things deliberately NOT done

- **Existing login screen was not modified.** The DPL endpoints
  `/auth/login`, `/auth/me`, `/auth/logout`, `/auth/change-password` are
  exposed in `DplApiService` for completeness, but the running app keeps
  using the existing login flow + JWT.
- **No new state-management library** was introduced.
- **Supervisor flow** ships as a placeholder for Phase 2.
- **Downtime report** shows an "empty" state until the supervisor
  module starts producing data.
