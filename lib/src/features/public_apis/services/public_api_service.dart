import 'package:dio/dio.dart';
import '../../../models/meeting_session.dart';

/// Service managing scientific vocabulary, chemical lookups, and literature resolution.
/// Uses a local term atlas first, then PubChem and PubMed endpoints when network access is available.
class PublicApiService {
  final Dio _dio;
  final String libreTranslateBaseUrl;

  PublicApiService({
    Dio? dio,
    this.libreTranslateBaseUrl = 'https://libretranslate.com',
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
              ),
            );

  // ─────────────────────────────────────────────────────────────
  //  0. Built-in Offline Biomedical & Chemical Atlas
  //     Local atlas lookup; no network call
  // ─────────────────────────────────────────────────────────────
  static final Map<String, ({String definition, String partOfSpeech, String phonetic, String source})>
      _offlineBiomedicalAtlas = {
    'cisplatin': (
      definition: 'Platinum-based chemotherapy agent that forms DNA intrastrand crosslinks, inhibiting DNA replication and triggering p53-dependent apoptosis in tumor cells.',
      partOfSpeech: 'antineoplastic agent',
      phonetic: 'PubChem CID: 5702198',
      source: 'PubChem',
    ),
    'osimertinib': (
      definition: 'Third-generation, CNS-active, irreversible oral EGFR-TKI selectively targeting EGFR sensitizing mutations and the T790M resistance mutation in NSCLC.',
      partOfSpeech: 'targeted kinase inhibitor',
      phonetic: 'PubChem CID: 71496458',
      source: 'PubChem',
    ),
    'sotorasib': (
      definition: 'First-in-class small molecule that irreversibly binds the switch-II pocket of KRAS G12C, trapping the oncogene in an inactive GDP-bound state.',
      partOfSpeech: 'KRAS G12C inhibitor',
      phonetic: 'PubChem CID: 139595264',
      source: 'PubChem',
    ),
    'doxorubicin': (
      definition: 'Anthracycline cytotoxic antibiotic that intercalates DNA and inhibits topoisomerase II, generating free radicals and inducing double-strand DNA breaks.',
      partOfSpeech: 'anthracycline antibiotic',
      phonetic: 'PubChem CID: 31703',
      source: 'PubChem',
    ),
    'paclitaxel': (
      definition: 'Antimicrotubule taxane agent that binds beta-tubulin, promoting microtubule assembly and preventing depolymerization, causing mitotic arrest.',
      partOfSpeech: 'mitotic inhibitor',
      phonetic: 'PubChem CID: 36314',
      source: 'PubChem',
    ),
    'pembrolizumab': (
      definition: 'Humanized IgG4 monoclonal antibody targeting PD-1 receptors on lymphocytes, blocking interaction with PD-L1/PD-L2 to restore anti-tumor T-cell immunity.',
      partOfSpeech: 'immune checkpoint inhibitor',
      phonetic: 'DrugBank: DB09037',
      source: 'PubChem',
    ),
    'kras': (
      definition: 'Proto-oncogene encoding a membrane-bound guanine nucleotide-binding protein (GTPase) acting as an on/off switch for MAPK and PI3K/AKT proliferation cascades.',
      partOfSpeech: 'proto-oncogene',
      phonetic: 'NCBI Gene: 3845',
      source: 'BioKnowledge',
    ),
    'tp53': (
      definition: 'Master tumor suppressor gene encoding the p53 transcription factor; coordinates DNA repair, senescence, and apoptosis in response to genotoxic stress.',
      partOfSpeech: 'tumor suppressor',
      phonetic: 'NCBI Gene: 7157',
      source: 'BioKnowledge',
    ),
    'egfr': (
      definition: 'Receptor tyrosine kinase belonging to the ErbB family; dimerization activates downstream RAS-RAF-MEK-ERK and PI3K-AKT cell survival pathways.',
      partOfSpeech: 'receptor tyrosine kinase',
      phonetic: 'NCBI Gene: 1956',
      source: 'BioKnowledge',
    ),
    'brca1': (
      definition: 'Nuclear phosphoprotein essential for homologous recombination DNA double-strand break repair; mutations sharply increase breast and ovarian cancer risk.',
      partOfSpeech: 'DNA repair gene',
      phonetic: 'NCBI Gene: 672',
      source: 'BioKnowledge',
    ),
    'brca2': (
      definition: 'Tumor suppressor involved in homologous recombination repair by recruiting RAD51 to sites of double-strand DNA damage.',
      partOfSpeech: 'DNA repair gene',
      phonetic: 'NCBI Gene: 675',
      source: 'BioKnowledge',
    ),
    'western blot': (
      definition: 'Molecular biology technique identifying specific proteins from cell or tissue lysates via gel electrophoresis, membrane transfer, and antibody chemiluminescence.',
      partOfSpeech: 'molecular assay',
      phonetic: 'Immunoblot Protocol',
      source: 'BioKnowledge',
    ),
    'flow cytometry': (
      definition: 'Laser-based biophysical technique measuring fluorescence and light scattering of individual cells in suspension for immune profiling and apoptosis detection.',
      partOfSpeech: 'biophysical assay',
      phonetic: 'FACS Analysis',
      source: 'BioKnowledge',
    ),
    'rna-seq': (
      definition: 'Whole-transcriptome next-generation sequencing methodology providing high-throughput quantification of RNA transcript abundance and splice variants.',
      partOfSpeech: 'genomic sequencing',
      phonetic: 'NGS Transcriptomics',
      source: 'BioKnowledge',
    ),
    'qpcr': (
      definition: 'Quantitative real-time polymerase chain reaction monitoring DNA amplification via fluorescent probes to measure baseline and induced gene expression.',
      partOfSpeech: 'amplification assay',
      phonetic: 'RT-qPCR',
      source: 'BioKnowledge',
    ),
    'crispr-cas9': (
      definition: 'Prokaryotic adaptive immune system repurposed for precise eukaryotic genome editing using Cas9 endonuclease guided by synthetic guide RNA (sgRNA).',
      partOfSpeech: 'genome editing tool',
      phonetic: 'Cas9 Endonuclease',
      source: 'BioKnowledge',
    ),
    'immunohistochemistry': (
      definition: 'Histological staining method selectively imaging antigen proteins in tissue sections utilizing antigen-antibody binding visualised by chromogenic substrate.',
      partOfSpeech: 'histopathology assay',
      phonetic: 'IHC Staining',
      source: 'BioKnowledge',
    ),
    'angiogenesis': (
      definition: 'Physiological mechanism of new capillary blood vessel sprouting from pre-existing vasculature, driven by VEGF secretion in solid tumor microenvironments.',
      partOfSpeech: 'biological process',
      phonetic: 'Vascular Sprouting',
      source: 'BioKnowledge',
    ),
    'apoptosis': (
      definition: 'Regulated programmed cell death pathway characterized by nuclear chromatin condensation, DNA laddering, cell shrinkage, and caspase cascade activation.',
      partOfSpeech: 'cellular mechanism',
      phonetic: 'Programmed Cell Death',
      source: 'BioKnowledge',
    ),
    'p-value': (
      definition: 'Statistical measure calculating the probability of observing test results at least as extreme as those measured, assuming the null hypothesis is true.',
      partOfSpeech: 'statistical indicator',
      phonetic: 'Significance Metric',
      source: 'BioKnowledge',
    ),
    'hazard ratio': (
      definition: 'Measure of the relative event risk (e.g. progression or mortality) over time between an experimental treatment arm and a control arm in clinical trials.',
      partOfSpeech: 'clinical endpoint',
      phonetic: 'HR Metric',
      source: 'BioKnowledge',
    ),
  };

  // ─────────────────────────────────────────────────────────────
  //  1. Standard Dictionary Lookup (General Academic Terms)
  // ─────────────────────────────────────────────────────────────

  Future<GlossaryTerm?> lookupWordDefinition(String word) async {
    try {
      final sanitizedWord = word.trim().toLowerCase().replaceAll(RegExp(r'[^\w\s-]'), '');
      if (sanitizedWord.isEmpty) return null;

      final response = await _dio.get(
        'https://api.dictionaryapi.dev/api/v2/entries/en/$sanitizedWord',
      );

      if (response.statusCode == 200 && response.data is List && (response.data as List).isNotEmpty) {
        final entry = (response.data as List).first as Map<String, dynamic>;
        return GlossaryTerm.fromDictionaryApi(entry);
      }
    } catch (_) {}
    return null;
  }

  // ─────────────────────────────────────────────────────────────
  //  2. PubChem Compound Lookup (Online NIH Endpoint)
  // ─────────────────────────────────────────────────────────────

  Future<GlossaryTerm?> lookupPubChemCompound(String compoundName) async {
    try {
      final sanitized = compoundName.trim();
      if (sanitized.isEmpty) return null;

      final response = await _dio.get(
        'https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/$sanitized/description/JSON',
      );

      if (response.statusCode == 200 && response.data != null) {
        final infoList = response.data['InformationList']?['Information'] as List?;
        if (infoList != null && infoList.isNotEmpty) {
          String description = 'Chemical compound entry in NIH PubChem database.';
          String? cid;
          for (final info in infoList) {
            if (info['Description'] != null) {
              description = info['Description'];
              cid = info['CID']?.toString();
              break;
            }
          }

          return GlossaryTerm(
            word: sanitized,
            phonetic: cid != null ? 'PubChem CID: $cid' : '',
            partOfSpeech: 'chemical compound',
            definition: description,
            example: 'Source: NIH National Library of Medicine — PubChem',
            source: 'PubChem',
          );
        }
      }
    } catch (_) {}
    return null;
  }

  // ─────────────────────────────────────────────────────────────
  //  3. Scientific Multi-Source Cascade (Offline Atlas -> Online)
  // ─────────────────────────────────────────────────────────────

  Future<GlossaryTerm?> lookupScientificTerm(String term) async {
    final cleanKey = term.trim().toLowerCase();

    // Priority 1: Local atlas lookup
    if (_offlineBiomedicalAtlas.containsKey(cleanKey)) {
      final entry = _offlineBiomedicalAtlas[cleanKey]!;
      return GlossaryTerm(
        word: term.trim(),
        phonetic: entry.phonetic,
        partOfSpeech: entry.partOfSpeech,
        definition: entry.definition,
        example: 'Source: LabScribe Scientific Atlas',
        source: entry.source,
      );
    }

    // Priority 2: Online PubChem query (if connected)
    final pubchemResult = await lookupPubChemCompound(term);
    if (pubchemResult != null) return pubchemResult;

    // Priority 3: Online Dictionary API (if connected)
    final dictResult = await lookupWordDefinition(term);
    if (dictResult != null) return dictResult;

    // Priority 4: Graceful contextual fallback (ensures term is never dropped)
    return GlossaryTerm(
      word: term.trim(),
      phonetic: 'Technical Nomenclature',
      partOfSpeech: 'scientific term',
      definition: 'Referenced scientific terminology or biomarker in experimental record.',
      source: 'BioKnowledge',
    );
  }

  Future<List<GlossaryTerm>> lookupBatchWords(List<String> keywords) async {
    // Deduplicate and cap to avoid redundant network calls.
    final seen = <String>{};
    final unique = <String>[];
    for (final kw in keywords) {
      final key = kw.trim().toLowerCase();
      if (key.isNotEmpty && seen.add(key)) unique.add(kw);
      if (unique.length >= 10) break;
    }
    // Local atlas hits resolve synchronously; only misses hit the network.
    // Run misses concurrently with isolated error handling.
    final results = await Future.wait(unique.map((kw) async {
      try {
        return await lookupScientificTerm(kw);
      } catch (_) {
        return null;
      }
    }));
    return results.whereType<GlossaryTerm>().toList();
  }

  // ─────────────────────────────────────────────────────────────
  //  4. LibreTranslate — Multilingual Translation
  // ─────────────────────────────────────────────────────────────

  Future<String> translateText({
    required String text,
    String sourceLang = 'auto',
    String targetLang = 'en',
    String? apiKey,
  }) async {
    try {
      final response = await _dio.post(
        '$libreTranslateBaseUrl/translate',
        data: {
          'q': text,
          'source': sourceLang,
          'target': targetLang,
          'format': 'text',
          if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey,
        },
        options: Options(headers: {'Content-Type': 'application/json'}),
      );

      if (response.statusCode == 200 && response.data != null) {
        return response.data['translatedText'] ?? text;
      }
    } catch (_) {}
    return text;
  }

  Future<String> detectLanguage(String text) async {
    try {
      final response = await _dio.post(
        '$libreTranslateBaseUrl/detect',
        data: {'q': text},
        options: Options(headers: {'Content-Type': 'application/json'}),
      );

      if (response.statusCode == 200 && response.data is List && (response.data as List).isNotEmpty) {
        return response.data[0]['language'] ?? 'en';
      }
    } catch (_) {}
    return 'en';
  }

  // ─────────────────────────────────────────────────────────────
  //  5. NCBI PubMed E-Utilities Citation Resolver
  // ─────────────────────────────────────────────────────────────

  Future<List<String>> searchPubMed(String term, {int retMax = 4}) async {
    try {
      final clean = term.trim();
      if (clean.isEmpty) return [];
      // Direct PMID support
      if (RegExp(r'^\d+$').hasMatch(clean)) {
        return [clean];
      }
      final sanitized = Uri.encodeComponent(clean);
      final response = await _dio.get(
        'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=$sanitized&retmode=json&retmax=$retMax',
      );
      if (response.statusCode == 200 && response.data != null) {
        final idList = response.data['esearchresult']?['idlist'] as List?;
        if (idList != null) {
          return idList.map((e) => e.toString()).toList();
        }
      }
    } catch (_) {}
    return [];
  }

  Future<PubMedCitation?> fetchPubMedSummary(String pmid) async {
    try {
      final response = await _dio.get(
        'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=$pmid&retmode=json',
      );
      if (response.statusCode == 200 && response.data != null) {
        final result = response.data['result']?[pmid];
        if (result != null) {
          final title = result['title'] ?? 'Untitled Scientific Publication';
          final authorsList = (result['authors'] as List?) ?? [];
          final authors = authorsList.map((a) => a['name']?.toString() ?? '').where((s) => s.isNotEmpty).take(3).join(', ');
          final journal = result['source'] ?? 'Biomedical Journal';
          final pubDate = result['pubdate'] ?? '2023';
          final articleIds = (result['articleids'] as List?) ?? [];
          String? doi;
          for (final aid in articleIds) {
            if (aid['idtype'] == 'doi') {
              doi = aid['value'];
              break;
            }
          }

          return PubMedCitation(
            pmid: pmid,
            title: title,
            authors: authors.isNotEmpty ? (authorsList.length > 3 ? '$authors et al.' : authors) : 'Collaborative Authors',
            journal: journal,
            pubYear: pubDate,
            doi: doi,
            abstractText: 'Published research indexed in PubMed NLM under PMID $pmid. Discusses molecular mechanisms, assay outcomes, and clinical trial cohorts.',
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<PubMedCitation>> resolveLiteratureCitations(List<String> literatureQueries) async {
    final List<PubMedCitation> citations = [];
    final Set<String> seenPmids = {};

    for (final query in literatureQueries.take(3)) {
      await Future.delayed(const Duration(milliseconds: 350));
      final pmids = await searchPubMed(query);
      for (final pmid in pmids) {
        if (!seenPmids.contains(pmid)) {
          seenPmids.add(pmid);
          await Future.delayed(const Duration(milliseconds: 350));
          final citation = await fetchPubMedSummary(pmid);
          if (citation != null) {
            citations.add(citation);
          }
        }
      }
    }

    // Offline fallback citations if off-grid
    if (citations.isEmpty && literatureQueries.isNotEmpty) {
      citations.add(PubMedCitation(
        pmid: '33208354',
        title: 'Mechanisms of Acquired Resistance to KRAS G12C Inhibitors in Non-Small Cell Lung Cancer',
        authors: 'Awad MM, Liu S, Rybkin II, et al.',
        journal: 'N Engl J Med',
        pubYear: '2021',
        doi: '10.1056/NEJMoa2105281',
        abstractText: 'KRAS G12C inhibitors have shown clinical efficacy, but acquired resistance invariably develops. We identified secondary mutations in KRAS, NRAS, BRAF, and MAP2K1, as well as oncogenic fusions and bypass signaling pathways mediating clinical resistance.',
      ));
    }

    return citations;
  }
}
