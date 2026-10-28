import 'package:flutter/material.dart';

import '../theme.dart';

class _Entry {
  const _Entry(this.term, this.plain, {this.detail});

  final String term;

  /// One sentence anyone can follow, with no other jargon in it.
  final String plain;

  /// Optional extra for a reader who wants the mechanism.
  final String? detail;
}

class _Section {
  const _Section(this.title, this.icon, this.entries);
  final String title;
  final IconData icon;
  final List<_Entry> entries;
}

/// Plain-language explanations of everything the app shows.
///
/// Written for whoever happens to be holding the device. An ENT specialist will
/// already know most of it, but the receptionist booking the follow-up and the
/// patient reading their own report will not, and neither should have to guess.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  static const _sections = [
    _Section('The test', Icons.hearing_rounded, [
      _Entry(
        'Pure-tone audiometry',
        'Playing single, steady beeps at different pitches and volumes to find '
            'the quietest one a person can hear.',
        detail: 'It measures hearing sensitivity, not how well someone '
            'understands speech. Those are different things, and a person can '
            'score well here and still struggle in a noisy room.',
      ),
      _Entry(
        'Threshold',
        'The quietest sound a person can just barely hear at one particular '
            'pitch.',
        detail: 'At threshold, detection is genuinely uncertain - the same '
            'sound is heard on some presentations and missed on others. That '
            'is why the test repeats each level rather than trusting one '
            'response.',
      ),
      _Entry(
        'Hughson-Westlake procedure',
        'The rule the app follows: go 10 dB quieter after a "yes", 5 dB louder '
            'after a "no", and repeat until the answers settle.',
        detail: 'A level counts as the threshold once the patient hears it on '
            'at least half of the tries approached from below, and at least '
            'twice (2 of 2, 2 of 3 or 2 of 4). Only rising approaches count, '
            'because hearing a tone on the way down only proves it was '
            'audible, not that it was the quietest audible one.',
      ),
      _Entry(
        'Familiarisation',
        'A practice tone at 1 kHz before the test starts. It is not scored.',
        detail: 'It checks that the patient presses when the tone starts and '
            'lets go when it stops. If they do not, the app repeats it once, '
            'then asks you to explain the task again.',
      ),
      _Entry(
        '1 kHz retest',
        'In the first ear, 1 kHz is measured again after the high pitches.',
        detail: 'If the two results are within 5 dB, the better one is kept. '
            'If they differ by more, the report flags it, 2 kHz is retested '
            'too, and the second ear also gets a 1 kHz retest.',
      ),
      _Entry(
        'Press and hold',
        'The patient presses when a tone starts and holds until it stops.',
        detail: 'A press while no tone is playing is counted and reported. '
            'Someone guessing cannot match the end of a tone they did not '
            'hear, so press and hold catches guessing better than tapping.',
      ),
      _Entry(
        'Catch trial',
        'A deliberate silent gap. If the patient presses the button during it, '
            'they are guessing.',
        detail: 'A few false presses are normal. A lot of them means the whole '
            'test should be repeated after re-explaining the task, and the '
            'report flags this automatically.',
      ),
      _Entry(
        'Masking',
        'Playing noise into the ear that is not being tested, so it cannot '
            'answer on behalf of the other one.',
        detail: 'Auris does not do this yet. It matters when one ear is much '
            'worse than the other, because a loud tone meant for the bad ear '
            'can travel through the skull and be heard by the good one. The '
            'report flags every frequency where the ears differ by 40 dB or '
            'more (55 dB with insert earphones).',
      ),
    ]),
    _Section('Reading the results', Icons.show_chart_rounded, [
      _Entry(
        'Audiogram',
        'The chart of the results: pitch across the bottom, loudness down the '
            'side.',
        detail: 'Quieter thresholds sit higher on the chart, so better hearing '
            'is higher up and a hearing loss makes the line sag downwards.',
      ),
      _Entry(
        'dB HL (decibels hearing level)',
        'How much louder than a normal young adult\'s faintest audible sound '
            'this person needs.',
        detail: '0 dB HL is roughly average normal hearing, not silence. '
            'Negative values are possible and simply mean better than average.',
      ),
      _Entry(
        'O and X markers',
        'A red circle is the right ear, a blue cross is the left ear.',
        detail: 'A universal convention on audiograms. The right ear is also '
            'joined with a solid line and the left with a dashed one, so the '
            'two stay distinguishable in a black-and-white printout.',
      ),
      _Entry(
        'NR (no response)',
        'The patient did not hear the tone even at the loudest level the app '
            'will play.',
        detail: 'It is not the same as "not tested". The true threshold is '
            'somewhere beyond the chart, so it is drawn as an arrow rather '
            'than joined to the neighbouring points.',
      ),
      _Entry(
        '≤ (at or below)',
        'The patient heard the quietest tone the app can play (-10 dB HL).',
        detail: 'Their real threshold may be even lower, so the value is shown '
            'as "≤-10" rather than as a measured threshold.',
      ),
      _Entry(
        'NE (not established)',
        'The test could not settle on a threshold at that pitch.',
        detail: 'Usually the answers were inconsistent. No number is reported '
            'for it; repeat that pitch after re-explaining the task.',
      ),
      _Entry(
        'PTA (pure-tone average)',
        'The average of the thresholds at the three pitches most important for '
            'understanding speech.',
        detail: 'Those are 500, 1000 and 2000 Hz. It is the single number used '
            'to summarise how much hearing loss there is.',
      ),
      _Entry(
        'Degree of hearing loss',
        'A label for how much loss the pure-tone average represents - from '
            'normal, through mild, moderate and severe, to profound.',
        detail: 'Up to 25 dB HL is normal; above 90 dB HL is profound. It says '
            'how much, not what kind or why.',
      ),
      _Entry(
        'Air conduction',
        'Sound delivered through headphones, the normal way sound reaches the '
            'ear.',
        detail: 'The alternative, bone conduction, uses a vibrator on the skull '
            'to bypass the outer and middle ear. Comparing the two is how a '
            'clinician tells a blockage from nerve damage. Auris does air '
            'conduction only, so it cannot make that distinction.',
      ),
    ]),
    _Section('Calibration', Icons.tune_rounded, [
      _Entry(
        'Calibration',
        'Teaching the app how loud your particular headphones actually are, so '
            'the numbers mean something real.',
        detail: 'The app controls a digital signal level. What reaches the ear '
            'also depends on the volume setting, the sound card and the '
            'headphones - none of which the app can see. Until it is told, the '
            'shape of the audiogram is meaningful but the numbers on the side '
            'are not.',
      ),
      _Entry(
        'dB SPL (sound pressure level)',
        'How loud a sound physically is, as a microphone would measure it.',
        detail: 'Different from dB HL, which is relative to normal hearing. '
            'Calibration is the bridge between the two.',
      ),
      _Entry(
        'Sound level meter',
        'The instrument that measures how loud a sound actually is.',
        detail: 'Any audiology or ENT department will have one. It is the only '
            'way to calibrate properly.',
      ),
      _Entry(
        'Biological check',
        'A rough calibration done by testing someone already known to hear '
            'normally.',
        detail: 'If a person with normal hearing appears to have a 30 dB loss '
            'on your setup, the setup is 30 dB too quiet, and the app corrects '
            'by that amount. Clinics use this as a daily sanity check. It is '
            'much better than nothing and clearly worse than a meter, because '
            'it inherits any error in the assumption that the reference person '
            'hears normally.',
      ),
      _Entry(
        'RETSPL',
        'A correction table for the fact that the ear is naturally less '
            'sensitive to low pitches than to middle ones.',
        detail: 'To sound equally loud, a 250 Hz tone has to be physically '
            'louder than a 1000 Hz one. The app applies this automatically; '
            'a tool that skipped it would not be measuring hearing level at '
            'all.',
      ),
      _Entry(
        'Transducer',
        'The headphones or earphones you are testing through.',
        detail: 'Recorded on every report, because a calibration is only valid '
            'for the exact device and headphones it was done on.',
      ),
    ]),
    _Section('Records and access', Icons.folder_shared_rounded, [
      _Entry(
        'Administrator, Clinician, Viewer',
        'Three levels of access: full control, run tests and edit records, or '
            'look only.',
        detail: 'A Viewer can read history and print reports but cannot run a '
            'test or change anything - suitable for reception. Only an '
            'Administrator can delete a patient, because that also deletes '
            'every test they have ever had.',
      ),
      _Entry(
        'Awaiting approval',
        'A new account that cannot see any records yet.',
        detail: 'Every account starts here. In cloud mode, a clinic admin (or '
            'a super admin) approves it in Settings, Clinic and team, '
            'Approvals. On a device without cloud sync, the first account is '
            'the administrator and approves the others in Settings, Team.',
      ),
      _Entry(
        'Super admin',
        'Runs Auris for several clinics: creates clinics and approves '
            'accounts for any of them.',
        detail: 'Set only in the database, never from the app. A super admin '
            'sees the patients of one home clinic at most, like that '
            'clinic\'s administrator, and decides the requests a clinic admin '
            'cannot (for example a clinic admin\'s own profile change).',
      ),
      _Entry(
        'Join code and Clinic ID',
        'How a new account finds its clinic.',
        detail: 'The join code (for example AUR-7K2PQ) is typed at sign-up or '
            'in My profile to ask to join; the clinic\'s admin still decides. '
            'The Clinic ID (for example CLN-0007) is the clinic\'s permanent '
            'number and never changes. Both are under My profile, My clinic.',
      ),
      _Entry(
        'Requests and approvals',
        'Changes others rely on wait for someone else to approve them.',
        detail: 'Changing your name, phone, qualification, registration '
            'number or email, joining or moving clinic, a clinic admin '
            'editing the clinic\'s details, and deleting an account are all '
            'requests. Nothing changes until approved. Your password, '
            'leaving a clinic and email alerts change at once. Your requests '
            'and what became of them are in My profile.',
      ),
      _Entry(
        'Local storage',
        'Records are saved on this device first, always.',
        detail: 'That is what lets a test finish even with no internet. A test '
            'that failed halfway because the connection dropped would mean '
            'calling the patient back.',
      ),
      _Entry(
        'Cloud sync',
        'An optional copy kept in an online database that one or more '
            'clinics share.',
        detail: 'It gives the same patient list on several devices and an '
            'off-site backup. It is off unless configured. The database '
            'itself only ever returns your own clinic\'s records, so clinics '
            'sharing it never see each other\'s patients.',
      ),
    ]),
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<_Section> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _sections;

    return [
      for (final section in _sections)
        if (section.entries.any((e) => _matches(e, q)))
          _Section(
            section.title,
            section.icon,
            section.entries.where((e) => _matches(e, q)).toList(),
          ),
    ];
  }

  bool _matches(_Entry e, String q) =>
      e.term.toLowerCase().contains(q) ||
      e.plain.toLowerCase().contains(q) ||
      (e.detail?.toLowerCase().contains(q) ?? false);

  @override
  Widget build(BuildContext context) {
    final sections = _filtered;

    return Scaffold(
      appBar: AppBar(title: const Text('Help & glossary')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Search - e.g. "dB HL", "masking", "PTA"',
                prefixIcon: const Icon(Icons.search_rounded,
                    color: AurisTheme.muted, size: 21),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 19),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: sections.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Nothing matches that. Try a shorter word.',
                        style: TextStyle(color: AurisTheme.muted),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                    children: [
                      for (final section in sections) ...[
                        Row(
                          children: [
                            Icon(section.icon,
                                size: 17, color: AurisTheme.primary),
                            const SizedBox(width: 8),
                            SectionLabel(section.title),
                          ],
                        ),
                        const SizedBox(height: 10),
                        for (final entry in section.entries)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _EntryCard(entry: entry),
                          ),
                        const SizedBox(height: 14),
                      ],
                      const SizedBox(height: 8),
                      const AurisCard(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline_rounded,
                                size: 18, color: AurisTheme.muted),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Auris is not a certified medical device. It '
                                'does not produce a diagnosis and does not '
                                'replace assessment by a qualified audiologist '
                                'or ENT specialist.',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.5,
                                    color: AurisTheme.muted),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _EntryCard extends StatefulWidget {
  const _EntryCard({required this.entry});
  final _Entry entry;

  @override
  State<_EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends State<_EntryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final hasDetail = entry.detail != null;

    return AurisCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: hasDetail ? () => setState(() => _expanded = !_expanded) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.term,
                  style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: AurisTheme.ink),
                ),
              ),
              if (hasDetail)
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: AurisTheme.muted,
                ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            entry.plain,
            style: const TextStyle(
                fontSize: 13.5, height: 1.5, color: AurisTheme.ink),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: AurisTheme.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  entry.detail ?? '',
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.55, color: AurisTheme.muted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
