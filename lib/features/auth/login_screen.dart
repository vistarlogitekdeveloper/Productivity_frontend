import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/theme_mode_provider.dart';
import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../core/widgets/vistar/vistar_ambient.dart';
import '../../core/widgets/vistar/vistar_brand.dart';
import '../../core/widgets/vistar/vistar_buttons.dart';
import '../dpl/core/dpl_organization_provider.dart';
import '../dpl/models/dpl_organization.dart';
import 'auth_repository.dart';
import 'auth_provider.dart';

/// Which login backend the form should authenticate against.
/// - [productivity]: classic Productivity flow (`/auth/login`, username + password)
/// - [vistarPulse]:  DPL flow (`/dpl/auth/login`, email + password)
enum _LoginFlow { productivity, vistarPulse }

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  bool _submittedOnce = false;
  String? _inlineError;

  /// Active login flow — drives field labels, validator, and which
  /// backend method gets called on Sign In.
  ///
  /// Defaults to Vistar Pulse: it is the primary flow, so the classic
  /// Productivity form (and the Vistar Workspace launcher reachable from
  /// it) is one tap away rather than the landing state.
  _LoginFlow _flow = _LoginFlow.vistarPulse;

  /// Selected organization for the Vistar Pulse flow. Required before
  /// Sign In is enabled; cleared when the flow toggles back to classic
  /// Productivity (which has no per-tenant scoping at login).
  int? _selectedOrgId;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  void _onLogin() {
    FocusScope.of(context).unfocus();
    setState(() => _submittedOnce = true);

    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_flow == _LoginFlow.vistarPulse && _selectedOrgId == null) {
      setState(() => _inlineError = 'Select an organization to continue.');
      return;
    }

    setState(() => _inlineError = null);
    final identifier = _usernameController.text.trim();
    final password = _passwordController.text;
    final auth = ref.read(authControllerProvider.notifier);

    switch (_flow) {
      case _LoginFlow.productivity:
        auth.login(identifier, password);
        break;
      case _LoginFlow.vistarPulse:
        auth.loginDpl(identifier, password, organizationId: _selectedOrgId);
        break;
    }
  }

  void _onFlowChanged(_LoginFlow next) {
    if (next == _flow) return;
    setState(() {
      _flow = next;
      _inlineError = null;
      _submittedOnce = false;
      _selectedOrgId = null;
    });
    // Username/email validation rules differ — re-run validation so any
    // stale error messages disappear once the user starts typing.
    _formKey.currentState?.reset();
    _usernameController.clear();
    _passwordController.clear();
  }

  String? _validateUsername(String? value) {
    final v = value?.trim() ?? '';
    if (_flow == _LoginFlow.vistarPulse) {
      if (v.isEmpty) return 'Email is required.';
      if (v.length > 254) return 'Email is too long.';
      // Pragmatic email shape — must contain `@` and a `.` in the domain.
      final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
      if (!emailRe.hasMatch(v)) return 'Enter a valid email address.';
      return null;
    }
    if (v.isEmpty) return 'Username is required.';
    if (v.length < 3) return 'Username must be at least 3 characters.';
    if (v.length > 40) return 'Username must be under 40 characters.';
    if (v.contains(' ')) return 'Username cannot contain spaces.';
    return null;
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Password is required.';
    if (password.length < 4) return 'Password must be at least 4 characters.';
    if (password.length > 128) return 'Password is too long.';
    return null;
  }

  /// Org picker shown above the email field on the Vistar Pulse flow.
  /// Reads [dplOrganizationListProvider]; handles loading/error/empty
  /// states inline so the form layout stays stable.
  Widget _buildOrgSelector(bool submitting) {
    final orgsAsync = ref.watch(dplOrganizationListProvider);

    return orgsAsync.when(
      loading: () => InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Organization',
          prefixIcon: Icon(Icons.apartment_outlined),
        ),
        child: const SizedBox(
          height: 20,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ShimmerButtonDots(size: 6, spacing: 3),
          ),
        ),
      ),
      error: (err, _) => InputDecorator(
        decoration: InputDecoration(
          labelText: 'Organization',
          prefixIcon: const Icon(Icons.apartment_outlined),
          errorText: _toDisplayError(err),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Could not load organizations.',
              style: TextStyle(color: VistarPalette.txt2),
            ),
            TextButton(
              onPressed: submitting
                  ? null
                  : () => ref.invalidate(dplOrganizationListProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (orgs) {
        if (orgs.isEmpty) {
          return InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Organization',
              prefixIcon: Icon(Icons.apartment_outlined),
              errorText: 'No organizations available. Contact your admin.',
            ),
            child: const SizedBox(height: 20),
          );
        }
        // Auto-select if there's only one tenant — no point making the
        // user open the dropdown to pick the single option.
        if (orgs.length == 1 && _selectedOrgId != orgs.first.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _selectedOrgId != orgs.first.id) {
              setState(() => _selectedOrgId = orgs.first.id);
            }
          });
        }
        return DropdownButtonFormField<int>(
          initialValue: _selectedOrgId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Organization',
            hintText: 'Select your organization',
            prefixIcon: Icon(Icons.apartment_outlined),
          ),
          items: [
            for (final DplOrganization org in orgs)
              DropdownMenuItem<int>(
                value: org.id,
                child: Text(org.displayLabel, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: submitting
              ? null
              : (id) {
                  setState(() {
                    _selectedOrgId = id;
                    if (_inlineError != null) _inlineError = null;
                  });
                },
          validator: (v) =>
              v == null ? 'Select an organization to continue.' : null,
        );
      },
    );
  }

  String _toDisplayError(Object error) {
    if (error is AuthException) {
      return error.message;
    }

    final raw = error.toString();
    const exceptionPrefix = 'Exception: ';
    if (raw.startsWith(exceptionPrefix)) {
      return raw.substring(exceptionPrefix.length).trim();
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final isLoading = authState.isLoading;
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;

    ref.listen(authControllerProvider, (previous, next) {
      if (!mounted) return;

      final justFailed = previous?.isLoading == true && next.hasError;
      if (justFailed) {
        final message = _toDisplayError(next.error!);
        setState(() => _inlineError = message);

        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: VistarPalette.badSolid,
              behavior: SnackBarBehavior.floating,
            ),
          );
      }

      final justSucceeded =
          previous?.isLoading == true && next.hasValue && next.value != null;
      if (justSucceeded) {
        final username = next.value!.username;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Welcome back, $username.'),
            backgroundColor: VistarPalette.okSolid,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });

    final themeToggle = _ThemeToggleButton(
      isDark: isDark,
      onPressed: () => ref.read(themeModeProvider.notifier).toggleThemeMode(),
    );

    return Scaffold(
      backgroundColor: VistarPalette.bg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 860;
          final form = _buildForm(context, isLoading, isWide: isWide);

          if (isWide) {
            // Split layout: brand "art" panel | form panel (1.05fr .95fr).
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Expanded(flex: 105, child: _LoginArtPanel()),
                Expanded(
                  flex: 95,
                  child: ColoredBox(
                    color: VistarPalette.bg2,
                    child: SafeArea(
                      child: Stack(
                        children: [
                          Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 48,
                                vertical: 32,
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 420,
                                ),
                                child: form,
                              ),
                            ),
                          ),
                          Positioned(top: 16, right: 16, child: themeToggle),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          }

          // Phone / narrow: condensed brand header above the form card.
          return VistarAmbientScaffoldBody(
            child: SafeArea(
              child: Stack(
                children: [
                  Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Center(child: VistarWordmark(height: 88)),
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                24,
                                22,
                                22,
                              ),
                              decoration: BoxDecoration(
                                color: VistarPalette.surface,
                                borderRadius: BorderRadius.circular(
                                  VistarPalette.rLg,
                                ),
                                border: Border.all(color: VistarPalette.line),
                                boxShadow: VistarPalette.shadow,
                              ),
                              child: form,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(top: 8, right: 8, child: themeToggle),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// The sign-in form — identical fields, validation and actions in both
  /// layouts; only the frame around it changes.
  Widget _buildForm(
    BuildContext context,
    bool isLoading, {
    required bool isWide,
  }) {
    final isPulse = _flow == _LoginFlow.vistarPulse;

    return AutofillGroup(
      child: Form(
        key: _formKey,
        autovalidateMode: _submittedOnce
            ? AutovalidateMode.onUserInteraction
            : AutovalidateMode.disabled,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const VistarMark(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isPulse ? 'Vistar Pulse' : 'Productivity',
                    style: GoogleFonts.bricolageGrotesque(
                      fontSize: isWide ? 30 : 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      height: 1.05,
                      color: VistarPalette.txt,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              isPulse
                  ? 'Sign in to manage daily production loading, shifts, and downtime on the shop floor.'
                  : 'Sign in to track classic production entries, quality, and operator activity.',
              style: GoogleFonts.manrope(
                fontSize: 14,
                height: 1.45,
                color: VistarPalette.txt2,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'SIGN IN WITH',
              style: GoogleFonts.manrope(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
                color: VistarPalette.txt3,
              ),
            ),
            const SizedBox(height: 8),
            // Flow toggle — Productivity (classic) vs Vistar Pulse (DPL),
            // as a role-chip grid; the active chip carries the ribbon.
            Row(
              children: [
                Expanded(
                  child: _FlowChip(
                    label: 'Productivity',
                    icon: Icons.bar_chart_outlined,
                    selected: !isPulse,
                    onTap: isLoading
                        ? null
                        : () => _onFlowChanged(_LoginFlow.productivity),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _FlowChip(
                    label: 'Vistar Pulse',
                    icon: Icons.factory_outlined,
                    selected: isPulse,
                    onTap: isLoading
                        ? null
                        : () => _onFlowChanged(_LoginFlow.vistarPulse),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            if (_inlineError != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: VistarPalette.badBg,
                  borderRadius: BorderRadius.circular(VistarPalette.rSm),
                  border: Border.all(color: VistarPalette.badLine),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: VistarPalette.bad),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _inlineError!,
                        style: TextStyle(
                          color: VistarPalette.badInk,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (isPulse) ...[
              _buildOrgSelector(isLoading),
              const SizedBox(height: 14),
            ],
            TextFormField(
              controller: _usernameController,
              focusNode: _usernameFocusNode,
              autofillHints: [
                isPulse ? AutofillHints.email : AutofillHints.username,
              ],
              keyboardType: isPulse
                  ? TextInputType.emailAddress
                  : TextInputType.text,
              textInputAction: TextInputAction.next,
              onFieldSubmitted: (_) => _passwordFocusNode.requestFocus(),
              enabled: !isLoading,
              onChanged: (_) {
                if (_inlineError != null) {
                  setState(() => _inlineError = null);
                }
              },
              decoration: InputDecoration(
                labelText: isPulse ? 'Email' : 'Username',
                hintText: isPulse
                    ? 'name@vistarlogitek.com'
                    : 'Enter your username',
                prefixIcon: Icon(
                  isPulse ? Icons.alternate_email : Icons.person_outline,
                ),
              ),
              validator: _validateUsername,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _passwordController,
              focusNode: _passwordFocusNode,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              enabled: !isLoading,
              obscureText: _obscurePassword,
              onChanged: (_) {
                if (_inlineError != null) {
                  setState(() => _inlineError = null);
                }
              },
              onFieldSubmitted: (_) => _onLogin(),
              decoration: InputDecoration(
                labelText: 'Password',
                hintText: 'Enter your password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
              validator: _validatePassword,
            ),
            const SizedBox(height: 22),
            VistarRibbonButton(
              height: 52,
              onPressed: isLoading ? null : _onLogin,
              child: isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: Center(
                        child: ShimmerButtonDots(size: 7, spacing: 3.5),
                      ),
                    )
                  : Text(
                      isPulse
                          ? 'Sign in to Vistar Pulse'
                          : 'Sign in to Productivity',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            Text(
              'Need access help? Contact your supervisor or admin.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: VistarPalette.txt3,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.role-chip` — one of the two sign-in flows. The active chip wears the
/// ribbon; the other sits quietly on the surface scale.
class _FlowChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  const _FlowChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(VistarPalette.rSm);
    final fg = selected ? Colors.white : VistarPalette.txt2;
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 46,
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: selected ? VistarPalette.ribbon : null,
          color: selected ? null : VistarPalette.surface2,
          border: selected ? null : Border.all(color: VistarPalette.line2),
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Color(0x66E0218A),
                    blurRadius: 22,
                    spreadRadius: -10,
                    offset: Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.manrope(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sun / moon switch in the login corner — lets people pick their mode
/// before signing in. Light is the default.
class _ThemeToggleButton extends StatelessWidget {
  final bool isDark;
  final VoidCallback onPressed;

  const _ThemeToggleButton({required this.isDark, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isDark ? 'Switch to light mode' : 'Switch to dark mode',
      child: Material(
        color: VistarPalette.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VistarPalette.rSm),
          side: BorderSide(color: VistarPalette.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(VistarPalette.rSm),
          onTap: onPressed,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 20,
              color: VistarPalette.txt2,
            ),
          ),
        ),
      ),
    );
  }
}

/// The brand "art" half of the wide login: aurora glows, an oversized
/// faint S, the wordmark, a pitch with one ribbon word, and three facts.
class _LoginArtPanel extends StatelessWidget {
  const _LoginArtPanel();

  @override
  Widget build(BuildContext context) {
    final dark = VistarPalette.isDark;
    final headline = GoogleFonts.bricolageGrotesque(
      fontSize: 48,
      height: 1.04,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.2,
      color: VistarPalette.txt,
    );
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const VistarAmbient(watermark: false),
          // Huge rotated S, opacity .16.
          Positioned(
            right: -120,
            bottom: -140,
            child: IgnorePointer(
              child: Transform.rotate(
                angle: -0.18,
                child: VistarMark(size: 620, opacity: dark ? 0.16 : 0.12),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(56, 44, 56, 44),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const VistarWordmark(height: 88),
                  const Spacer(),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text.rich(
                      TextSpan(
                        style: headline,
                        children: [
                          const TextSpan(
                            text: 'Every shift, every pallet,\none ',
                          ),
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: VistarRibbonText('pulse', style: headline),
                          ),
                          const TextSpan(text: '.'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Text(
                      'Plan, produce, inspect and dispatch — live from the '
                      'shop floor to the loading dock, for every role on '
                      'the team.',
                      style: GoogleFonts.manrope(
                        fontSize: 15.5,
                        height: 1.55,
                        color: VistarPalette.txt2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 34),
                  const Wrap(
                    spacing: 36,
                    runSpacing: 18,
                    children: [
                      _ArtStat(
                        value: 'Live',
                        caption: 'Shift timers & downtime',
                      ),
                      _ArtStat(value: 'QR', caption: 'Signed dispatch slips'),
                      _ArtStat(
                        value: 'Plan → Dock',
                        caption: 'One flow, every role',
                      ),
                    ],
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtStat extends StatelessWidget {
  final String value;
  final String caption;

  const _ArtStat({required this.value, required this.caption});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        VistarRibbonText(
          value,
          style: GoogleFonts.bricolageGrotesque(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          caption,
          style: GoogleFonts.manrope(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: VistarPalette.txt3,
          ),
        ),
      ],
    );
  }
}
