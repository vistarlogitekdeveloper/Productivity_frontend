/// Models for the Administration panel (backend migration 148).
///
/// Everything an administrator maintains: the people, the organizations they
/// belong to, the catalogue of things a role may do, and the grid that says
/// which roles may do them.
library;

import '_json_helpers.dart';

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

/// One account, as the Administration screen sees it.
///
/// There is no password field and never will be: the backend does not return
/// the hash, and an administrator can only ever SET a new password, never read
/// the existing one.
class DplManagedUser {
  final int id;
  final int organizationId;
  final String organizationCode;
  final String organizationName;

  final String name;
  final String email;
  final String employeeCode;
  final String role;

  /// Whether the person can log in. Accounts are disabled, never deleted —
  /// every sticker, scan and slip points at the user who made it.
  final bool isActive;

  /// True right after an administrator created the account or reset its
  /// password. Cleared the moment the user sets their own.
  final bool mustChangePassword;

  final DateTime? disabledAt;
  final DateTime? lastLoginAt;
  final DateTime? createdAt;

  const DplManagedUser({
    this.id = 0,
    this.organizationId = 0,
    this.organizationCode = '',
    this.organizationName = '',
    this.name = '',
    this.email = '',
    this.employeeCode = '',
    this.role = '',
    this.isActive = true,
    this.mustChangePassword = false,
    this.disabledAt,
    this.lastLoginAt,
    this.createdAt,
  });

  factory DplManagedUser.fromJson(Map<String, dynamic> json) {
    final org = json['organization'];
    final orgMap = org is Map ? Map<String, dynamic>.from(org) : const {};
    return DplManagedUser(
      id: parseIntOr(json['id']),
      organizationId: parseIntOr(json['organization_id'] ?? json['organizationId']),
      organizationCode: parseStringOr(orgMap['code']),
      organizationName: parseStringOr(orgMap['name']),
      name: parseStringOr(json['name']),
      email: parseStringOr(json['email']),
      employeeCode: parseStringOr(json['employee_code'] ?? json['employeeCode']),
      role: parseStringOr(json['role']),
      isActive: json['is_active'] is bool
          ? json['is_active'] as bool
          : json['isActive'] is bool
              ? json['isActive'] as bool
              : true,
      mustChangePassword: json['must_change_password'] == true ||
          json['mustChangePassword'] == true,
      disabledAt: parseDateTimeOrNull(json['disabled_at'] ?? json['disabledAt']),
      lastLoginAt: parseDateTimeOrNull(json['last_login_at'] ?? json['lastLoginAt']),
      createdAt: parseDateTimeOrNull(json['created_at'] ?? json['createdAt']),
    );
  }

  /// What the admin screen shows as the tenant. Falls back through name, code
  /// and id so a partially-loaded row never renders as blank.
  String get organizationLabel {
    if (organizationName.trim().isNotEmpty) return organizationName.trim();
    if (organizationCode.trim().isNotEmpty) return organizationCode.trim();
    return organizationId > 0 ? 'Org #$organizationId' : '—';
  }

  /// Never logged in at all — worth calling out, because it usually means the
  /// person was never told their password rather than that they are inactive.
  bool get hasNeverLoggedIn => lastLoginAt == null;

  Map<String, dynamic> toCreateJson({required String password}) => {
        'organization_id': organizationId,
        'name': name.trim(),
        'email': email.trim(),
        'employee_code': employeeCode.trim().isEmpty ? null : employeeCode.trim(),
        'role': role,
        'password': password,
        'is_active': isActive,
        'must_change_password': mustChangePassword,
      };

  /// The update body. Sends only the identity fields — status and password
  /// have their own endpoints, because "rename this person" and "lock this
  /// person out" should not be the same request.
  Map<String, dynamic> toUpdateJson() => {
        'organization_id': organizationId,
        'name': name.trim(),
        'email': email.trim(),
        'employee_code': employeeCode.trim().isEmpty ? null : employeeCode.trim(),
        'role': role,
      };

  DplManagedUser copyWith({
    int? organizationId,
    String? organizationCode,
    String? organizationName,
    String? name,
    String? email,
    String? employeeCode,
    String? role,
    bool? isActive,
    bool? mustChangePassword,
  }) {
    return DplManagedUser(
      id: id,
      organizationId: organizationId ?? this.organizationId,
      organizationCode: organizationCode ?? this.organizationCode,
      organizationName: organizationName ?? this.organizationName,
      name: name ?? this.name,
      email: email ?? this.email,
      employeeCode: employeeCode ?? this.employeeCode,
      role: role ?? this.role,
      isActive: isActive ?? this.isActive,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      disabledAt: disabledAt,
      lastLoginAt: lastLoginAt,
      createdAt: createdAt,
    );
  }
}

/// One page of the user list.
class DplManagedUserPage {
  final List<DplManagedUser> users;
  final int page;
  final int limit;
  final int total;

  const DplManagedUserPage({
    this.users = const [],
    this.page = 1,
    this.limit = 50,
    this.total = 0,
  });

  factory DplManagedUserPage.fromJson(Map<String, dynamic> json) {
    final raw = json['users'];
    return DplManagedUserPage(
      users: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DplManagedUser.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      page: parseIntOr(json['page'], 1),
      limit: parseIntOr(json['limit'], 50),
      total: parseIntOr(json['total']),
    );
  }

  bool get hasMore => users.length >= limit && page * limit < total;
}

// ---------------------------------------------------------------------------
// Organizations
// ---------------------------------------------------------------------------

/// An organization as the administrator maintains it.
///
/// Distinct from `DplOrganization`, which is the slim (id, code, name) record
/// the login screen and the AppBar pill use. This one carries the headcount
/// and the active flag, which only the admin panel has any business knowing.
class DplAdminOrganization {
  final int id;
  final String code;
  final String name;
  final bool isActive;
  final int userCount;

  const DplAdminOrganization({
    this.id = 0,
    this.code = '',
    this.name = '',
    this.isActive = true,
    this.userCount = 0,
  });

  factory DplAdminOrganization.fromJson(Map<String, dynamic> json) {
    return DplAdminOrganization(
      id: parseIntOr(json['id']),
      code: parseStringOr(json['code']),
      name: parseStringOr(json['name']),
      isActive: json['is_active'] is bool ? json['is_active'] as bool : true,
      userCount: parseIntOr(json['user_count'] ?? json['userCount']),
    );
  }

  Map<String, dynamic> toJsonForWrite() => {
        'code': code.trim().toUpperCase(),
        'name': name.trim(),
        'is_active': isActive,
      };

  String get label => name.trim().isNotEmpty ? name.trim() : code;
}

// ---------------------------------------------------------------------------
// Permission catalogue
// ---------------------------------------------------------------------------

class DplRoleInfo {
  final String key;
  final String label;
  final String description;

  const DplRoleInfo({this.key = '', this.label = '', this.description = ''});

  factory DplRoleInfo.fromJson(Map<String, dynamic> json) => DplRoleInfo(
        key: parseStringOr(json['key']),
        label: parseStringOr(json['label']),
        description: parseStringOr(json['description']),
      );
}

class DplPermissionInfo {
  final String key;
  final String label;
  final String description;

  const DplPermissionInfo({
    this.key = '',
    this.label = '',
    this.description = '',
  });

  factory DplPermissionInfo.fromJson(Map<String, dynamic> json) =>
      DplPermissionInfo(
        key: parseStringOr(json['key']),
        label: parseStringOr(json['label']),
        description: parseStringOr(json['description']),
      );
}

class DplPermissionGroup {
  final String key;
  final String label;
  final List<DplPermissionInfo> permissions;

  const DplPermissionGroup({
    this.key = '',
    this.label = '',
    this.permissions = const [],
  });

  factory DplPermissionGroup.fromJson(Map<String, dynamic> json) {
    final raw = json['permissions'];
    return DplPermissionGroup(
      key: parseStringOr(json['key']),
      label: parseStringOr(json['label']),
      permissions: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DplPermissionInfo.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }
}

/// One cell of the grid.
class DplPermissionCell {
  final bool allowed;

  /// What the built-in default says, regardless of any override.
  final bool isDefault;

  /// True when an administrator has deliberately set this cell. The screen
  /// marks these, because a decision someone made and a value that was
  /// inherited should not look identical.
  final bool isOverride;

  /// Cells the backend refuses to change — the Administrator role cannot give
  /// up the permissions needed to hand them back.
  final bool locked;

  const DplPermissionCell({
    this.allowed = false,
    this.isDefault = false,
    this.isOverride = false,
    this.locked = false,
  });

  factory DplPermissionCell.fromJson(Map<String, dynamic> json) =>
      DplPermissionCell(
        allowed: json['allowed'] == true,
        isDefault: json['is_default'] == true,
        isOverride: json['is_override'] == true,
        locked: json['locked'] == true,
      );

  DplPermissionCell copyWith({bool? allowed}) => DplPermissionCell(
        allowed: allowed ?? this.allowed,
        isDefault: isDefault,
        // A cell that now differs from the default IS an override, whether or
        // not it has been saved yet — the screen has to mark it immediately or
        // an unsaved change looks the same as an inherited value.
        isOverride: (allowed ?? this.allowed) != isDefault,
        locked: locked,
      );
}

/// The whole grid for one organization.
class DplPermissionMatrix {
  final int organizationId;
  final List<DplRoleInfo> roles;
  final List<DplPermissionGroup> groups;

  /// `grants[role][permissionKey]`.
  final Map<String, Map<String, DplPermissionCell>> grants;

  const DplPermissionMatrix({
    this.organizationId = 0,
    this.roles = const [],
    this.groups = const [],
    this.grants = const {},
  });

  factory DplPermissionMatrix.fromJson(Map<String, dynamic> json) {
    final rawRoles = json['roles'];
    final rawGroups = json['permission_groups'] ?? json['permissionGroups'];
    final rawGrants = json['grants'];

    final grants = <String, Map<String, DplPermissionCell>>{};
    if (rawGrants is Map) {
      rawGrants.forEach((role, cells) {
        if (cells is! Map) return;
        final byKey = <String, DplPermissionCell>{};
        cells.forEach((key, cell) {
          if (cell is Map) {
            byKey[key.toString()] =
                DplPermissionCell.fromJson(Map<String, dynamic>.from(cell));
          }
        });
        grants[role.toString()] = byKey;
      });
    }

    return DplPermissionMatrix(
      organizationId:
          parseIntOr(json['organization_id'] ?? json['organizationId']),
      roles: rawRoles is List
          ? rawRoles
              .whereType<Map>()
              .map((e) => DplRoleInfo.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      groups: rawGroups is List
          ? rawGroups
              .whereType<Map>()
              .map((e) => DplPermissionGroup.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      grants: grants,
    );
  }

  DplPermissionCell cell(String role, String permissionKey) =>
      grants[role]?[permissionKey] ?? const DplPermissionCell();

  /// A copy with one cell flipped. Used for the local edit buffer so the grid
  /// stays responsive and one save carries every change for that role.
  DplPermissionMatrix withCell(String role, String key, bool allowed) {
    final next = <String, Map<String, DplPermissionCell>>{};
    grants.forEach((r, cells) => next[r] = Map<String, DplPermissionCell>.from(cells));
    final row = next[role] ?? <String, DplPermissionCell>{};
    row[key] = (row[key] ?? const DplPermissionCell()).copyWith(allowed: allowed);
    next[role] = row;
    return DplPermissionMatrix(
      organizationId: organizationId,
      roles: roles,
      groups: groups,
      grants: next,
    );
  }

  /// How many cells for [role] differ from the built-in default.
  int overrideCountFor(String role) {
    final row = grants[role];
    if (row == null) return 0;
    return row.values.where((c) => c.allowed != c.isDefault).length;
  }
}

// ---------------------------------------------------------------------------
// Audit
// ---------------------------------------------------------------------------

/// One entry in the account-change trail.
class DplUserAuditEntry {
  final int id;
  final int organizationId;
  final String actorName;
  final String targetEmail;
  final String action;
  final Map<String, dynamic> changes;
  final DateTime? createdAt;

  const DplUserAuditEntry({
    this.id = 0,
    this.organizationId = 0,
    this.actorName = '',
    this.targetEmail = '',
    this.action = '',
    this.changes = const {},
    this.createdAt,
  });

  factory DplUserAuditEntry.fromJson(Map<String, dynamic> json) {
    final raw = json['changes'];
    return DplUserAuditEntry(
      id: parseIntOr(json['id']),
      organizationId: parseIntOr(json['organization_id']),
      actorName: parseStringOr(json['actor_name']),
      targetEmail: parseStringOr(json['target_email']),
      action: parseStringOr(json['action']),
      changes: raw is Map ? Map<String, dynamic>.from(raw) : const {},
      createdAt: parseDateTimeOrNull(json['created_at']),
    );
  }

  /// Plain-language version of the `action` column.
  String get actionLabel {
    switch (action) {
      case 'created':
        return 'Account created';
      case 'updated':
        return 'Details changed';
      case 'role_changed':
        return 'Role changed';
      case 'disabled':
        return 'Account disabled';
      case 'enabled':
        return 'Account enabled';
      case 'password_reset':
        return 'Password reset';
      case 'org_created':
        return 'Organization created';
      case 'org_updated':
        return 'Organization changed';
      case 'permissions_changed':
        return 'Access rules changed';
      default:
        return action.isEmpty ? '—' : action;
    }
  }

  /// One line summarising `changes`, e.g. "role: dpl_qa to dpl_manager".
  /// Returns an empty string when there is nothing meaningful to show, which
  /// is correct for a password reset — there, the action is the whole story.
  String get changeSummary {
    if (changes.isEmpty) return '';

    // Permission edits nest under `permissions` rather than being flat
    // field diffs, so they need their own phrasing.
    final perms = changes['permissions'];
    if (perms is Map) {
      final role = parseStringOr(changes['role']);
      final granted = <String>[];
      final revoked = <String>[];
      perms.forEach((key, value) {
        if (value is Map && value['to'] == true) {
          granted.add(key.toString());
        } else if (value is Map) {
          revoked.add(key.toString());
        }
      });
      final parts = <String>[
        if (granted.isNotEmpty) '+${granted.length} granted',
        if (revoked.isNotEmpty) '-${revoked.length} revoked',
      ];
      return '$role · ${parts.join(', ')}';
    }
    if (changes['reset_to_defaults'] == true) {
      return '${parseStringOr(changes['role'])} · reset to defaults';
    }

    final parts = <String>[];
    changes.forEach((field, value) {
      if (value is Map && value.containsKey('to')) {
        final from = parseStringOr(value['from'], '—');
        final to = parseStringOr(value['to'], '—');
        parts.add('$field: ${from.isEmpty ? '—' : from} to ${to.isEmpty ? '—' : to}');
      }
    });
    return parts.join(' · ');
  }
}
