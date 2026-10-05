import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/workspace/data/vistar_app_catalog.dart';
import 'package:productivity_tracker/features/workspace/models/vistar_app.dart';
import 'package:productivity_tracker/features/workspace/services/vistar_sso_handoff.dart';
import 'package:productivity_tracker/features/workspace/services/workspace_credentials.dart';
import 'package:productivity_tracker/features/workspace/workspace_account.dart';

void main() {
  const handoff = VistarSsoHandoff();
  const identity = VistarSsoIdentity(
    email: 'prashant.tamhankar@vistarlogitek.com',
    name: 'Prashant Tamhankar',
    role: 'VISTAR_WORKSPACE',
    password: 's3cret-pass',
  );

  /// Pulls the envelope from wherever the transport put it — query, or the
  /// query inside the hash route. Mirrors what a receiver has to do.
  Map<String, String> handoffParams(Uri uri) {
    if (uri.queryParameters.containsKey(VistarSsoHandoff.envelopeParam)) {
      return uri.queryParameters;
    }
    final parts = uri.fragment.split('?');
    return parts.length > 1 ? Uri.splitQueryString(parts[1]) : const {};
  }

  Map<String, dynamic> decodeEnvelope(Uri uri) {
    final raw = handoffParams(uri)[VistarSsoHandoff.envelopeParam]!;
    // base64url padding is stripped when the token is minted.
    final padded = raw.padRight((raw.length + 3) & ~3, '=');
    return jsonDecode(utf8.decode(base64Url.decode(padded)))
        as Map<String, dynamic>;
  }

  group('VistarSsoHandoff.buildUrl', () {
    const app = VistarApp(
      id: 'kra',
      name: 'KRA',
      tagline: 'Goals.',
      url: 'https://kra.flutter-developer.workers.dev/',
      category: 'People',
      icon: Icons.track_changes_outlined,
      accent: <Color>[Color(0xFFC018C0), Color(0xFFE0218A)],
    );

    test('keeps the app origin and path untouched', () {
      final uri = handoff.buildUrl(app, identity);
      expect(uri.host, 'kra.flutter-developer.workers.dev');
      expect(uri.scheme, 'https');
      expect(uri.path, '/');
    });

    test('carries the identity, audience and a short expiry', () {
      final now = DateTime.utc(2026, 8, 8, 10, 0, 0);
      final uri = handoff.buildUrl(app, identity, now: now);
      final envelope = decodeEnvelope(uri);

      expect(envelope['v'], 2);
      expect(envelope['sub'], identity.email);
      expect(envelope['name'], identity.name);
      expect(envelope['role'], identity.role);
      expect(envelope['app'], 'kra');
      expect(envelope['src'], VistarSsoHandoff.source);
      expect(
        envelope['exp'] as int,
        (envelope['iat'] as int) + VistarSsoHandoff.ttlSeconds,
      );
      expect(envelope['iat'], now.millisecondsSinceEpoch ~/ 1000);
    });

    test('forwards the password so the target can log the user in', () {
      final envelope = decodeEnvelope(handoff.buildUrl(app, identity));
      expect(envelope['pwd'], 's3cret-pass');
    });

    test('omits pwd entirely when the launcher no longer holds it', () {
      const noPassword = VistarSsoIdentity(
        email: 'someone@vistarlogitek.com',
        name: 'Someone',
        role: 'VISTAR_WORKSPACE',
      );
      final envelope = decodeEnvelope(handoff.buildUrl(app, noPassword));
      // Absent, not null — a receiver must distinguish "no auto-login
      // available" from "auto-login failed".
      expect(envelope.containsKey('pwd'), isFalse);
      expect(noPassword.canAutoLogin, isFalse);
    });

    test('never leaks the password through toString', () {
      expect(identity.toString(), isNot(contains('s3cret-pass')));
      expect(
        const WorkspaceCredentials(
          username: 'u',
          password: 's3cret-pass',
        ).toString(),
        isNot(contains('s3cret-pass')),
      );
    });

    test('TTL stays short — the envelope carries a password in a URL', () {
      expect(VistarSsoHandoff.ttlSeconds, lessThanOrEqualTo(60));
    });

    test('fragment transport keeps the envelope off the wire', () {
      const viaFragment = VistarApp(
        id: 'kra',
        name: 'KRA',
        tagline: 'Goals.',
        url: 'https://kra.flutter-developer.workers.dev/',
        category: 'People',
        icon: Icons.track_changes_outlined,
        accent: <Color>[Color(0xFFC018C0), Color(0xFFE0218A)],
        transport: VistarSsoTransport.fragment,
        hashRoute: '/login',
      );
      final uri = handoff.buildUrl(viaFragment, identity);

      // Nothing sensitive in the part the server sees. Browsers never
      // transmit the fragment, so strip it and assert the remainder — the
      // actual request line — is free of the hand-off.
      final onTheWire = uri.removeFragment().toString();
      expect(uri.query, isEmpty);
      expect(onTheWire, isNot(contains('vsso')));
      expect(onTheWire, isNot(contains('email')));
      expect(onTheWire, isNot(contains('s3cret-pass')));
      // ...and the receiver can still find it in the hash route.
      expect(uri.fragment, startsWith('/login?'));
      expect(decodeEnvelope(uri)['pwd'], 's3cret-pass');
    });

    test('adds the flat email + src hints for simple targets', () {
      final uri = handoff.buildUrl(app, identity);
      expect(uri.queryParameters[VistarSsoHandoff.emailParam], identity.email);
      expect(
        uri.queryParameters[VistarSsoHandoff.sourceParam],
        VistarSsoHandoff.source,
      );
    });

    test('preserves query params already on the app URL', () {
      const withQuery = VistarApp(
        id: 'gate-app',
        name: 'Gate App',
        tagline: 'Gate register.',
        url: 'https://gate-app.flutter-developer.workers.dev/?plant=pune',
        category: 'Operations',
        icon: Icons.sensor_door_outlined,
        accent: <Color>[Color(0xFFC8102E), Color(0xFFF06000)],
      );
      final uri = handoff.buildUrl(withQuery, identity);
      expect(uri.queryParameters['plant'], 'pune');
      expect(
        uri.queryParameters.containsKey(VistarSsoHandoff.envelopeParam),
        isTrue,
      );
    });

    test('attaches nothing when the app opts out of the hand-off', () {
      const plain = VistarApp(
        id: 'plain',
        name: 'Plain',
        tagline: 'No SSO.',
        url: 'https://example.com/',
        category: 'Other',
        icon: Icons.link,
        accent: <Color>[Color(0xFF7A1FB0), Color(0xFF9B30C9)],
        sso: VistarSsoMode.plain,
      );
      expect(handoff.buildUrl(plain, identity).query, isEmpty);
    });
  });

  group('catalog', () {
    test('ids are unique — they are the SSO audience claim', () {
      final ids = kVistarAppCatalog.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every app points at an absolute https URL', () {
      for (final app in kVistarAppCatalog) {
        final uri = Uri.parse(app.url);
        expect(uri.scheme, 'https', reason: '${app.name} must be https');
        expect(uri.host, isNotEmpty, reason: '${app.name} needs a host');
      }
    });

    test('search matches on name, category and host', () {
      final pulse = kVistarAppCatalog.firstWhere((a) => a.id == 'vistar-pulse');
      expect(pulse.matches('pulse'), isTrue);
      expect(pulse.matches('OPERATIONS'), isTrue);
      expect(pulse.matches('productivity-frontend'), isTrue);
      expect(pulse.matches('sangopan'), isFalse);
      expect(pulse.matches('   '), isTrue);
    });
  });

  group('WorkspaceCredentialsStore', () {
    ProviderContainer container() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('starts empty — nothing is held before a login', () {
      expect(container().read(workspaceCredentialsProvider), isNull);
    });

    test('holds what was typed, and drops it on clear', () {
      final c = container();
      final store = c.read(workspaceCredentialsProvider.notifier);

      store.set('user@vistarlogitek.com', 'typed-pass');
      final held = c.read(workspaceCredentialsProvider);
      expect(held?.username, 'user@vistarlogitek.com');
      expect(held?.password, 'typed-pass');
      expect(held?.isUsable, isTrue);

      store.clear();
      expect(c.read(workspaceCredentialsProvider), isNull);
    });

    test('recovers the portal password after a refresh wiped memory', () {
      final c = container();
      final store = c.read(workspaceCredentialsProvider.notifier);

      expect(store.restoreIfKnown(VistarWorkspaceAccount.username), isTrue);
      expect(
        c.read(workspaceCredentialsProvider)?.password,
        VistarWorkspaceAccount.knownPassword,
      );
    });

    test('recovery is case-insensitive on the username', () {
      final c = container();
      expect(
        c
            .read(workspaceCredentialsProvider.notifier)
            .restoreIfKnown('  Prashant.Tamhankar@VistarLogitek.com '),
        isTrue,
      );
    });

    test('refuses to invent a password for any other account', () {
      final c = container();
      final store = c.read(workspaceCredentialsProvider.notifier);

      expect(store.restoreIfKnown('someone.else@vistarlogitek.com'), isFalse);
      expect(c.read(workspaceCredentialsProvider), isNull);
    });
  });

  group('VistarWorkspaceAccount', () {
    test('accepts the portal credentials, case-insensitive on username', () {
      expect(
        VistarWorkspaceAccount.matches(
          '  Prashant.Tamhankar@VistarLogitek.com ',
          '12345678',
        ),
        isTrue,
      );
    });

    test('is shaped like an email, as the login form expects', () {
      // The login form's field is an email field. The portal account skips
      // its validators, but the username must still look like what a person
      // would type there.
      expect(
        RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
            .hasMatch(VistarWorkspaceAccount.username),
        isTrue,
      );
    });

    test('rejects a wrong password or a different user', () {
      expect(
        VistarWorkspaceAccount.matches(VistarWorkspaceAccount.username, '1234'),
        isFalse,
      );
      expect(
        VistarWorkspaceAccount.matches('someone@vistarlogitek.com', '12345678'),
        isFalse,
      );
    });
  });
}
