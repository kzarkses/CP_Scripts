// reaper_cpclip — point d'entree de l'extension, et la surface CP_* appelable
// depuis Lua.
//
// Trois responsabilites, et rien d'autre :
//   1. charger l'API REAPER et enregistrer les fonctions CP_*
//   2. decoder les fichiers (via les PCM_source de REAPER, donc tous les
//      formats que REAPER lit) vers le vivier du coeur
//   3. tenir un apercu permanent par colonne, et l'horloge
//
// Le coeur (src/core) ignore tout de ce fichier. C'est ce qui le rend
// verifiable hors REAPER, et ce qui garde le fil audio honnete.

#define REAPERAPI_IMPLEMENT
#include "reaper_plugin.h"
#include "reaper_plugin_functions.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <new>

#include "cp_source.h"
#include "../core/cp_engine.h"

using namespace cp;

// Version de l'ABI. Lua DOIT la verifier avant tout autre appel : ReaPack n'a
// aucun mecanisme de dependance (mesure : 89 index, 5993 paquets, zero element
// de dependance), donc un script peut tres bien s'installer sans le binaire, ou
// avec une version qui ne parle pas la meme langue.
// 1.1 : ajout de CP_VoiceStartedAt. Un ajout leve la mineure ; un changement de
// signature leverait la majeure. Les scripts exigent un MINIMUM, pas une egalite
// — sinon chaque ajout casserait tout le monde.
// 1.4 : CP_WarpProbe — la mesure de l'etireur de REAPER.
// 1.6 : LES LANES MIDI. Le moteur ne joue plus seulement des echantillons, il
//       tient les boucles : modes, quantize de lancement, horloge libre, porte
//       par bloc. Avec elles disparaissent CP_MidiLooper.jsfx, la piste
//       routeur, ses envois filtres par canal, gmem comme protocole, et le
//       plafond de quatre colonnes — qui ne venait pas d'un MAX_LANES mais du
//       budget de seize canaux MIDI d'une seule piste.
// 1.5 : CP_PortAttachOut (sortie materielle, sans piste), parametres de voix
//       « pos » et « loop », CP_ClipLoad refuse au-dela du plafond au lieu de
//       tronquer en silence, CP_VoiceAlloc refuse sur un port sans sortie.
static const double kEngineABI = 1.6;

// ---------------------------------------------------------------------------
// Etat global. Le moteur pese plusieurs centaines de kilo-octets : il vit sur
// le tas, alloue une seule fois au chargement, jamais pendant le jeu.
// ---------------------------------------------------------------------------
static Engine* g_eng = nullptr;

struct Port {
  PortSource*         src;
  preview_register_t  reg;
  bool                active;
  // Un apercu de PISTE et un apercu MATERIEL ne se retirent pas par la meme
  // fonction. Se tromper laisse l'apercu vivant et le PCM_source detruit sous
  // ses pieds : ce n'est pas un bug, c'est un plantage de l'hote.
  bool                hardware;
};
static Port g_ports[kMaxPorts];

static audio_hook_register_t g_hook;
static bool g_hook_on = false;

// REAPER passe rec = NULL au dechargement : on garde donc le pointeur recu au
// chargement, sinon plus rien n'est desenregistrable.
static reaper_plugin_info_t* g_rec = nullptr;

// Ancre de l'horloge : le seul point de contact entre le temps du projet et le
// temps du moteur. Prise sur le fil principal, les deux lectures collees l'une
// a l'autre — l'erreur vaut le temps entre elles (des microsecondes), pas une
// frame de defer (16 a 74 ms). C'est ce qui permet au fil audio de ne JAMAIS
// demander l'heure : il compte, et cette ancre lui dit une fois ou il est.
static double  g_anchor_pos = 0.0;
static int64_t g_anchor_smp = 0;

// ---------------------------------------------------------------------------
// Hook materiel : le battement de l'horloge.
// ---------------------------------------------------------------------------
static void OnAudioBuffer(bool isPost, int len, double srate,
                          audio_hook_register_t* reg) {
  (void)reg;
  if (!isPost) return;   // le passage POST : le bloc vient d'etre delivre
  if (!g_eng || len <= 0) return;
  if (srate > 1.0 && srate != g_eng->srate()) g_eng->set_srate(srate);
  g_eng->tick(len);
}

// ---------------------------------------------------------------------------
// Decodage d'un fichier vers le vivier.
//
// On passe par les PCM_source de REAPER : aucun format n'est perdu, et le
// reechantillonnage vers le taux du moteur est fait par REAPER lui-meme. Le
// clip est donc stocke PRET A LIRE : a taux 1.0, la lecture est une copie
// bit-exacte, sans interpolation. C'est ce que le harnais verifie.
//
// v1 : decodage synchrone, sur le fil appelant (donc le fil principal, depuis
// Lua). Une boucle de 16 mesures se decode en quelques millisecondes. Le fil de
// travail viendra quand la duree maximale d'un clip changera.
// ---------------------------------------------------------------------------
static int decode_to_pool(const char* path) {
  if (!path || !*path || !g_eng) return -1;

  // La memoire d'un clip retire n'est rendue qu'apres deux blocs audio. Ce
  // passage est le bon endroit pour la reclamer : c'est la seule fonction dont
  // on sait qu'elle sera rappelee, et elle est sur le fil principal.
  g_eng->pool().collect(g_eng->block_index());

  PCM_source* src = PCM_Source_CreateFromFile(path);
  if (!src) return -1;

  const double esr = g_eng->srate();
  const double len_s = src->GetLength();
  int nch = src->GetNumChannels();
  if (nch < 1) nch = 1;
  if (nch > kMaxChans) nch = kMaxChans;

  if (len_s <= 0.0) { PCM_Source_Destroy(src); return -1; }

  frame_t frames = (frame_t)(len_s * esr + 0.5);
  if (frames <= 0) { PCM_Source_Destroy(src); return -1; }

  // LE PLAFOND REFUSE, IL NE TRONQUE PAS.
  //
  // Il tronquait, et c'etait la faute que ce depot se reproche partout ailleurs :
  // le contrat annonce « rend nil au-dela de 64 s », le code rendait un clip
  // ampute sans un mot. Un fichier de trois minutes serait entre dans le vivier
  // comme une boucle de soixante-quatre secondes, et le defaut se serait
  // manifeste comme une fin prematuree inexplicable, jamais comme un refus.
  //
  // -2 et non -1 : l'appelant doit pouvoir dire « ce fichier est trop long »
  // plutot que « ce fichier est illisible ». Ce n'est pas la meme phrase.
  if (frames > kMaxClipFrames) { PCM_Source_Destroy(src); return -2; }

  const int slot = g_eng->pool().acquire();
  if (slot < 0) { PCM_Source_Destroy(src); return -1; }
  if (!g_eng->pool().alloc(slot, frames, nch, esr)) {
    g_eng->pool().fail(slot);
    PCM_Source_Destroy(src);
    return -1;
  }

  sample_t* dst = g_eng->pool().writable(slot);
  const int kChunk = 4096;
  ReaSample* tmp = (ReaSample*)malloc((size_t)kChunk * kMaxChans * sizeof(ReaSample));
  if (!tmp || !dst) {
    free(tmp);
    g_eng->pool().fail(slot);
    PCM_Source_Destroy(src);
    return -1;
  }

  frame_t done = 0;
  while (done < frames) {
    const int n = (int)((frames - done > kChunk) ? kChunk : (frames - done));
    memset(tmp, 0, (size_t)n * nch * sizeof(ReaSample));

    PCM_source_transfer_t tr;
    memset(&tr, 0, sizeof(tr));
    tr.time_s = (double)done / esr;
    tr.samplerate = esr;
    tr.nch = nch;
    tr.length = n;
    tr.samples = tmp;
    tr.samples_out = 0;
    src->GetSamples(&tr);

    const int got = (tr.samples_out > 0 && tr.samples_out <= n) ? tr.samples_out : n;
    for (int i = 0; i < got; ++i)
      for (int ch = 0; ch < nch; ++ch)
        dst[(size_t)(done + i) * nch + ch] = (sample_t)tmp[(size_t)i * nch + ch];

    done += got;
    if (got <= 0) break; // source epuisee : on garde ce qu'on a
  }

  free(tmp);
  PCM_Source_Destroy(src);
  g_eng->pool().publish(slot);
  return slot;
}

// ---------------------------------------------------------------------------
// Surface CP_* — plate et ennuyeuse, exactement comme le dossier le demande :
// un ABI qu'on renegocie est un cauchemar.
//
// Les handles circulent en double : un uint32 y tient exactement, et Lua ne
// connait que des doubles.
// ---------------------------------------------------------------------------
extern "C" {

double CP_EngineABI() { return kEngineABI; }

double CP_Srate() { return g_eng ? g_eng->srate() : 0.0; }

double CP_ClipLoad(const char* path) { return (double)decode_to_pool(path); }

void CP_ClipUnload(double clip) {
  if (!g_eng) return;
  // collect() AVANT retire() : ce passage rend ce que le PRECEDENT retrait a
  // laisse derriere lui. Appele apres, il ne rendrait jamais rien — la barriere
  // de deux blocs n'est par construction jamais franchie dans le meme appel.
  g_eng->pool().collect(g_eng->block_index());
  g_eng->pool().retire((int)clip, g_eng->block_index());
}

bool CP_ClipInfo(double clip, double* framesOut, double* srateOut, double* nchOut) {
  if (!g_eng) return false;
  const Clip* c = g_eng->pool().get((int)clip);
  if (!c) return false;
  if (framesOut) *framesOut = (double)c->frames;
  if (srateOut)  *srateOut  = c->srate;
  if (nchOut)    *nchOut    = (double)c->nch;
  return true;
}

// Installe l'apercu permanent d'un port. `track` non nul => la sortie traverse
// la chaine d'effets de cette piste ; `track` nul => sortie materielle a partir
// du canal outchan (0 = la premiere paire).
//
// La sortie materielle n'est pas un ajout de confort : c'est le comportement
// par defaut d'un navigateur de fichiers, qui ecoute avant de choisir une piste.
// Sans elle, le moteur natif ne peut tout simplement pas remplacer CF_Preview
// dans CP_MediaExplorer.
static bool port_open(int port, MediaTrack* track, int outchan) {
  if (!g_eng || port < 0 || port >= kMaxPorts) return false;
  if (g_ports[port].active) return true;   // idempotent, comme tout le reste

  PortSource* s = new (std::nothrow) PortSource(g_eng, port);
  if (!s) return false;

  Port& p = g_ports[port];
  memset(&p.reg, 0, sizeof(p.reg));
#ifdef _WIN32
  InitializeCriticalSection(&p.reg.cs);
#else
  pthread_mutex_init(&p.reg.mutex, NULL);
#endif
  p.reg.src = s;
  p.reg.curpos = 0.0;
  p.reg.loop = true;              // ne s'arrete jamais de lui-meme
  p.reg.volume = 1.0;
  p.hardware = (track == nullptr);

  // measure_align = 0 : c'est NOUS qui datons, a l'echantillon. L'alignement de
  // mesure de REAPER est plus grossier que ce que le moteur sait faire.
  // Un pointeur de fonction non resolu s'appelle une fois et emporte l'hote.
  // REAPERAPI_LoadAPI ne rend une erreur que pour les fonctions qu'il juge
  // indispensables ; celles-ci sont chargees au mieux.
  int ok = 0;
  if (p.hardware) {
    p.reg.m_out_chan = (outchan < 0) ? 0 : outchan;
    p.reg.preview_track = nullptr;
    if (PlayPreviewEx) ok = PlayPreviewEx(&p.reg, 0, 0.0);
  } else {
    p.reg.m_out_chan = -1;        // -1 => preview_track est pris en compte
    p.reg.preview_track = track;
    if (PlayTrackPreview2Ex) ok = PlayTrackPreview2Ex(0, &p.reg, 0, 0.0);
  }

  if (!ok) {
#ifdef _WIN32
    DeleteCriticalSection(&p.reg.cs);
#endif
    delete s;
    return false;
  }
  p.src = s;
  p.active = true;
  return true;
}

bool CP_PortAttach(MediaTrack* track, int port) {
  if (!track) return false;
  return port_open(port, track, -1);
}

bool CP_PortAttachOut(int port, int outchan) {
  return port_open(port, nullptr, outchan);
}

void CP_PortDetach(int port) {
  if (port < 0 || port >= kMaxPorts) return;
  Port& p = g_ports[port];
  if (!p.active) return;
  // L'arret rend la main quand l'apercu est retire : a partir de la, ce port ne
  // rend plus. C'est SEULEMENT a ce moment qu'on peut reprendre ses voix de
  // force — sinon une voix en fondu de sortie n'a plus personne pour faire
  // avancer son fondu, et son emplacement est perdu jusqu'au redemarrage.
  if (p.hardware) { if (StopPreview) StopPreview(&p.reg); }
  else            { if (StopTrackPreview2) StopTrackPreview2(0, &p.reg); }
  if (g_eng) g_eng->port_reset(port);
#ifdef _WIN32
  DeleteCriticalSection(&p.reg.cs);
#endif
  delete p.src;
  p.src = nullptr;
  p.active = false;
  p.hardware = false;
}

bool CP_PortActive(int port) {
  if (port < 0 || port >= kMaxPorts) return false;
  return g_ports[port].active;
}

void CP_PortGain(int port, double gain) {
  if (!g_eng) return;
  Cmd c; memset(&c, 0, sizeof(c));
  c.type = kCmdPortGain; c.at = kNow; c.a = gain; c.u1 = (uint32_t)port;
  g_eng->post(port, c);
}

double CP_VoiceAlloc(int port) {
  if (!g_eng) return (double)kNullVoice;
  // Un port sans sortie ne rend pas, donc son anneau n'est jamais draine : une
  // voix allouee la ne sonnerait jamais ET ne pourrait jamais etre rendue. On
  // refuse au lieu de fuir en silence. C'est aussi la reponse honnete a
  // l'appelant : « il n'y a pas de sortie », et non « plus de voix ».
  if (port < 0 || port >= kMaxPorts || !g_ports[port].active)
    return (double)kNullVoice;
  return (double)g_eng->voice_alloc(port);
}

void CP_VoiceRelease(double h) {
  if (g_eng) g_eng->voice_release((voice_h)h);
}

bool CP_VoicePlayAtSample(double h, double clip, double atSample, int mode,
                          double rate, double gain) {
  if (!g_eng) return false;
  const voice_h v = (voice_h)h;
  const int p = g_eng->voice_port(v);
  if (p < 0) return false;
  Cmd c; memset(&c, 0, sizeof(c));
  c.type = kCmdVoicePlay;
  c.voice = v;
  c.at = (frame_t)atSample;
  c.a = (rate > 0.0) ? rate : 1.0;
  c.b = gain;
  c.u0 = (uint32_t)(int)clip;
  c.u1 = (uint32_t)mode;
  return g_eng->post(p, c);
}

bool CP_VoiceStopAtSample(double h, double atSample, double fade) {
  if (!g_eng) return false;
  const voice_h v = (voice_h)h;
  const int p = g_eng->voice_port(v);
  if (p < 0) return false;
  Cmd c; memset(&c, 0, sizeof(c));
  c.type = kCmdVoiceStop;
  c.voice = v;
  c.at = (frame_t)atSample;
  c.a = fade;
  return g_eng->post(p, c);
}

bool CP_VoiceSet(double h, const char* param, double value) {
  if (!g_eng || !param) return false;
  const voice_h v = (voice_h)h;
  const int p = g_eng->voice_port(v);
  if (p < 0) return false;
  uint32_t id;
  if      (!strcmp(param, "rate"))       id = kParamRate;
  else if (!strcmp(param, "gain"))       id = kParamGain;
  else if (!strcmp(param, "pan"))        id = kParamPan;
  else if (!strcmp(param, "loop_start")) id = kParamLoopStart;
  else if (!strcmp(param, "loop_end"))   id = kParamLoopEnd;
  else if (!strcmp(param, "fade_in"))    id = kParamFadeIn;
  else if (!strcmp(param, "fade_out"))   id = kParamFadeOut;
  else if (!strcmp(param, "pos"))        id = kParamPos;
  else if (!strcmp(param, "loop"))       id = kParamLoop;
  else return false;
  Cmd c; memset(&c, 0, sizeof(c));
  c.type = kCmdVoiceSet; c.voice = v; c.at = kNow; c.u0 = id; c.a = value;
  return g_eng->post(p, c);
}

bool CP_VoiceQueueNext(double h, double nextH, double xfade) {
  if (!g_eng) return false;
  const voice_h v = (voice_h)h;
  const int p = g_eng->voice_port(v);
  if (p < 0) return false;
  // Les deux voix doivent vivre sur le meme port : l'enchainement se resout
  // dans le rendu de ce port, il ne traverse pas les colonnes.
  if (g_eng->voice_port((voice_h)nextH) != p) return false;
  Cmd c; memset(&c, 0, sizeof(c));
  c.type = kCmdVoiceQueue; c.voice = v; c.at = kNow;
  c.u0 = (uint32_t)nextH; c.a = xfade;
  return g_eng->post(p, c);
}

bool CP_VoiceState(double h, double* posOut, double* stateOut) {
  if (!g_eng) return false;
  double pos = 0; int st = 0;
  if (!g_eng->voice_query((voice_h)h, &pos, &st)) return false;
  if (posOut) *posOut = pos;
  if (stateOut) *stateOut = (double)st;
  return true;
}

// La verite terrain de l'attaque, notee par la voix au moment ou elle sonne.
// A preferer TOUJOURS a un calcul externe (horloge - position) : celui-ci voit
// un bloc d'ecart quand la lecture tombe entre le pull de l'apercu et le
// passage post du hook.
double CP_VoiceStartedAt(double h) {
  if (!g_eng) return -1.0;
  return (double)g_eng->voice_started_at((voice_h)h);
}

// EXPERIMENTAL — la sonde du §12.9.1, et rien d'autre.
//
// Depose une note-on datee et sa note-off dans le flux MIDI du bloc que REAPER
// nous tend. La question n'est pas « est-ce que ca marche » mais « est-ce que
// REAPER route le MIDI d'un apercu de PISTE vers la chaine de cette piste ».
// Si oui, l'affranchissement du JSFX est total. Si non, on aura la reponse en
// une soiree plutot qu'en discutant.
//
// Ce n'est PAS l'interface MIDI definitive : celle-ci passerait par des voix,
// comme l'audio. On ne dessine pas l'ABI d'une chose dont on ignore encore si
// elle existe.
bool CP_TestMidiAt(int port, double atSample, int note, int vel, double durSamples) {
  if (port < 0 || port >= kMaxPorts) return false;
  Port& p = g_ports[port];
  if (!p.active || !p.src) return false;
  const frame_t on = (frame_t)atSample;
  const frame_t off = on + (frame_t)((durSamples > 0.0) ? durSamples : 4800.0);
  const unsigned char n = (unsigned char)(note & 0x7F);
  const unsigned char v = (unsigned char)(vel & 0x7F);
  if (!p.src->queue_midi(on, 0x90, n, v)) return false;
  return p.src->queue_midi(off, 0x80, n, 0);
}

const char* CP_TestMidiDiag() {
  static char buf[256];
  int nlist = 0;
  long long out = 0, exact = 0, late = 0, maxerr = 0;
  for (int i = 0; i < kMaxPorts; ++i) {
    if (!g_ports[i].active || !g_ports[i].src) continue;
    if (g_ports[i].src->midi_seen_list()) ++nlist;
    out += g_ports[i].src->midi_out();
    exact += g_ports[i].src->midi_exact();
    late += g_ports[i].src->midi_late();
    if (g_ports[i].src->midi_max_err() > maxerr) maxerr = g_ports[i].src->midi_max_err();
  }
  snprintf(buf, sizeof(buf),
           "midi_events_fourni_par_reaper=%d evenements_remis=%lld exacts=%lld "
           "en_retard=%lld erreur_max=%lld spl",
           nlist, out, exact, late, maxerr);
  return buf;
}

// ---------------------------------------------------------------------------
// Montee en charge : ce que le moteur coute vraiment au fil audio.
//
// Un port ne dit rien de huit. Et « ca a l'air fluide » ne dit rien du tout sur
// une machine qui n'est pas la machine cible : seul un pourcentage mesure le dit.
// ---------------------------------------------------------------------------
static frame_t   g_load_blocks0 = 0;
static long long g_load_calls0[kMaxPorts];

void CP_LoadReset() {
  if (!g_eng) return;
  PortSource_ResetBusy();
  g_load_blocks0 = g_eng->block_index();
  for (int i = 0; i < kMaxPorts; ++i)
    g_load_calls0[i] = (g_ports[i].active && g_ports[i].src) ? g_ports[i].src->calls() : 0;
}

const char* CP_LoadDiag() {
  static char buf[384];
  if (!g_eng) { snprintf(buf, sizeof(buf), "engine=none"); return buf; }

  const frame_t db = g_eng->block_index() - g_load_blocks0;
  int nports = 0;
  double ratio_min = 1e9;
  for (int i = 0; i < kMaxPorts; ++i) {
    if (!g_ports[i].active || !g_ports[i].src) continue;
    ++nports;
    if (db > 0) {
      const double rr = (double)(g_ports[i].src->calls() - g_load_calls0[i]) / (double)db;
      if (rr < ratio_min) ratio_min = rr;
    }
  }
  // -1 et non 0 quand rien n'est encore mesurable : un zero se lit comme « le
  // port ne recoit rien », ce qui est le contraire de « on ne sait pas encore ».
  // La premiere campagne a rendu un faux verdict pour cette seule raison.
  if (ratio_min > 1e8 || db <= 0) ratio_min = -1.0;

  // Part du fil audio consommee par le moteur : temps passe dans GetSamples
  // rapporte au temps que ces blocs representent reellement.
  const long long freq = PortSource_TickFreq();
  const double busy_s = (freq > 0) ? (double)PortSource_BusyTicks() / (double)freq : 0.0;
  const double audio_s = (g_eng->srate() > 0.0)
                       ? (double)db * g_eng->last_block_frames() / g_eng->srate() : 0.0;
  const double cpu = (audio_s > 0.0) ? (busy_s / audio_s * 100.0) : 0.0;

  snprintf(buf, sizeof(buf),
           "ports=%d voix=%d bloc=%d blocs=%lld ratio_min=%.4f cpu=%.2f%% "
           "dropped=%u ram=%.2fMo",
           nports, g_eng->active_voices(), g_eng->last_block_frames(),
           (long long)db, ratio_min, cpu, g_eng->dropped_commands(),
           (double)g_eng->pool().bytes_resident() / (1024.0 * 1024.0));
  return buf;
}

// ---------------------------------------------------------------------------
// LE WARP — la sonde du §12.5.5, et le dernier argument irreductible du dossier.
//
// Deux questions, une seule fonction :
//
//   1. QUELLE EST LA LATENCE de l'etireur de REAPER ? L'interface n'expose
//      aucun accesseur (§11.9) : c'est un modele push/pull, donc la latence
//      s'OBSERVE — on pousse une impulsion et on compte les echantillons de
//      sortie qui la precedent. Et surtout elle s'AMORCE : connaitre ce nombre
//      permet de pre-remplir l'etireur pour que le premier echantillon utile
//      tombe pile sur le beat.
//
//   2. COMBIEN COUTE-T-IL par voix ? 16 voix etirees sur un PC de 2005
//      n'existent peut-etre pas, quel que soit le code. Mieux vaut le savoir
//      avant d'ecrire le moteur autour.
//
// Tout se passe sur le fil principal : c'est une mesure, pas du temps reel.
// ---------------------------------------------------------------------------
const char* CP_WarpProbe(double tempoRatio, int nvoices) {
  static char buf[512];

  if (!ReaperGetPitchShiftAPI) {
    snprintf(buf, sizeof(buf), "ReaperGetPitchShiftAPI indisponible");
    return buf;
  }
  IReaperPitchShift* ps = ReaperGetPitchShiftAPI(REAPER_PITCHSHIFT_API_VER);
  if (!ps) {
    snprintf(buf, sizeof(buf), "l'etireur a refuse la version 0x%X",
             REAPER_PITCHSHIFT_API_VER);
    return buf;
  }

  const double srate = g_eng ? g_eng->srate() : 48000.0;
  const int    nch = 2;
  const double tempo = (tempoRatio > 0.01) ? tempoRatio : 1.0;

  ps->set_srate(srate);
  ps->set_nch(nch);
  ps->set_shift(1.0);            // la hauteur ne bouge pas : c'est tout l'objet
  ps->set_tempo(tempo);
  ps->SetQualityParameter(-1);   // reglage par defaut du projet
  ps->Reset();

  // --- 1. la latence, par impulsion ----------------------------------------
  //
  // Une impulsion au tout premier echantillon d'entree, puis du silence. On
  // compte ce qui sort avant elle. Deux nombres, parce qu'un etireur a fenetre
  // ETALE une impulsion : le premier echantillon non nul dit quand la sortie
  // commence a exister, le pic dit ou l'energie est reellement arrivee. C'est le
  // pic qui sert a compenser.
  const int kChunk = 256;
  const int kWantOut = 16384;
  static ReaSample out[16384 * 2];

  long long total_in = 0, total_out = 0;
  long long premier = -1, pic_idx = -1;
  double pic_val = 0.0;
  bool impulsion_poussee = false;

  // LA vraie latence. Elle ne se manifeste PAS par des zeros en tete de sortie :
  // l'impulsion ressort a l'index 0, ce qui veut dire que la sortie commence
  // bien a l'echantillon source 0. Elle se manifeste par une sortie qui
  // N'EXISTE PAS ENCORE — il faut avoir pousse un certain nombre d'echantillons
  // avant que le premier ne sorte. C'est ce nombre qu'il faut connaitre, et il
  // se paie en AMORCAGE, pas en compensation : on pre-remplit l'etireur avant
  // l'instant de lancement, et le premier echantillon utile tombe pile.
  long long amorce = -1;   // entree poussee avant la premiere sortie

  int garde = 4096;   // borne dure : on ne boucle jamais indefiniment
  while (total_out < kWantOut && garde-- > 0) {
    ReaSample* in = ps->GetBuffer(kChunk);
    if (!in) break;
    for (int i = 0; i < kChunk * nch; ++i) in[i] = 0.0;
    if (!impulsion_poussee) {
      in[0] = 1.0;
      in[1] = 1.0;
      impulsion_poussee = true;
    }
    ps->BufferDone(kChunk);
    total_in += kChunk;

    const int got = ps->GetSamples(kChunk, out);
    if (got > 0 && amorce < 0) amorce = total_in;
    for (int i = 0; i < got; ++i) {
      const double v = (out[(size_t)i * nch] < 0.0) ? -out[(size_t)i * nch]
                                                    : out[(size_t)i * nch];
      const long long idx = total_out + i;
      if (premier < 0 && v > 1e-6) premier = idx;
      if (v > pic_val) { pic_val = v; pic_idx = idx; }
    }
    total_out += got;
    if (got <= 0 && total_in > (long long)kWantOut * 4) break;
  }

  // --- 2. le cout, par voix -------------------------------------------------
  //
  // On traite une seconde d'audio a travers N etireurs et on rapporte le temps
  // mur au temps audio. C'est la meme unite que le cpu= de la montee en charge,
  // donc les deux chiffres se comparent directement.
  int n = (nvoices < 1) ? 1 : ((nvoices > 16) ? 16 : nvoices);
  IReaperPitchShift* pool[16];
  int made = 0;
  for (int i = 0; i < n; ++i) {
    IReaperPitchShift* p = ReaperGetPitchShiftAPI(REAPER_PITCHSHIFT_API_VER);
    if (!p) break;
    p->set_srate(srate);
    p->set_nch(nch);
    p->set_shift(1.0);
    p->set_tempo(tempo);
    p->SetQualityParameter(-1);
    p->Reset();
    pool[made++] = p;
  }

  const int kSecFrames = (int)srate;
  double phase = 0.0;
  const long long freq = PortSource_TickFreq();
  LARGE_INTEGER li0, li1;
  QueryPerformanceCounter(&li0);

  for (int v = 0; v < made; ++v) {
    IReaperPitchShift* p = pool[v];
    int done = 0;
    phase = 0.0;
    while (done < kSecFrames) {
      const int c = ((kSecFrames - done) > kChunk) ? kChunk : (kSecFrames - done);
      ReaSample* in = p->GetBuffer(c);
      if (!in) break;
      // Une sinusoide plutot que du silence : un etireur qui ne recoit que des
      // zeros peut court-circuiter son traitement, et on mesurerait le vide.
      for (int i = 0; i < c; ++i) {
        const double s = 0.5 * sin(phase);
        phase += 2.0 * 3.14159265358979 * 220.0 / srate;
        in[(size_t)i * nch] = s;
        in[(size_t)i * nch + 1] = s;
      }
      p->BufferDone(c);
      p->GetSamples(c, out);
      done += c;
    }
  }

  QueryPerformanceCounter(&li1);
  const double mur = (freq > 0)
      ? (double)(li1.QuadPart - li0.QuadPart) / (double)freq : 0.0;

  for (int i = 0; i < made; ++i) delete pool[i];
  delete ps;

  const double par_voix = (made > 0) ? (mur / made * 100.0) : 0.0;

  // Solde en vol : ce que l'etireur retient encore quand on arrete de le nourrir,
  // ramene en echantillons d'ENTREE. A tempo t, une sortie vaut t entrees.
  const double solde = (double)total_in - (double)total_out * tempo;

  snprintf(buf, sizeof(buf),
           "tempo=%.4f | AMORCE=%lld spl (%.2f ms) | solde_en_vol=%.0f spl (%.2f ms) "
           "| impulsion: premier=%lld pic=%lld (donc la sortie commence bien a la "
           "source 0) | in=%lld out=%lld | cout: %d voix, %.1f ms mur pour 1 s "
           "audio = %.2f%%/voix",
           tempo,
           amorce, (amorce > 0) ? (double)amorce / srate * 1000.0 : 0.0,
           solde, solde / srate * 1000.0,
           premier, pic_idx, total_in, total_out,
           made, mur * 1000.0, par_voix);
  return buf;
}

double CP_ClockNow() { return g_eng ? (double)g_eng->clock_now() : 0.0; }

// Prend l'ancre. Les deux lectures sont collees volontairement : tout ce qui se
// glisse entre elles devient de l'erreur.
double CP_ClockSync() {
  if (!g_eng) return 0.0;
  const int64_t s = g_eng->clock_now();
  const double  p = GetPlayPosition();
  g_anchor_smp = s;
  g_anchor_pos = p;
  // Le battement du fil principal, et donc le bon endroit pour rendre la memoire
  // des clips retires : le contrat dit qu'une fenetre appelle ceci une fois par
  // frame. Sans point de passage regulier, un clip decharge pendant qu'aucun
  // autre n'est charge garderait sa RAM jusqu'a la fermeture.
  g_eng->pool().collect(g_eng->block_index());
  return (double)s;
}

double CP_TimeToSample(double projectTime) {
  if (!g_eng) return 0.0;
  return (double)g_anchor_smp + (projectTime - g_anchor_pos) * g_eng->srate();
}

void CP_Panic() { if (g_eng) g_eng->panic(); }

// Rend une chaine plutot qu'un tampon de sortie : la convention ReaScript des
// parametres `bufOut` / `bufOutNeedBig` a plusieurs variantes et je ne peux pas
// la verifier ici. Un `const char*` de retour est sans ambiguite. Le tampon est
// statique et l'appel est reserve au fil principal — c'est ecrit, pas suppose.
const char* CP_Diag() {
  static char buf[512];
  const int buf_sz = (int)sizeof(buf);
  if (!g_eng) { snprintf(buf, buf_sz, "engine=none"); return buf; }
  int nports = 0;
  double maxgap = 0.0;
  int64_t calls = 0;
  for (int i = 0; i < kMaxPorts; ++i) {
    if (!g_ports[i].active || !g_ports[i].src) continue;
    ++nports;
    if (g_ports[i].src->max_gap_s() > maxgap) maxgap = g_ports[i].src->max_gap_s();
    calls += g_ports[i].src->calls();
  }
  snprintf(buf, buf_sz,
           "abi=%.1f srate=%.0f bloc=%d clock=%lld blocks=%lld voices=%d/%d "
           "clips=%d ram=%.2fMo ports=%d hook=%d calls=%lld maxgap=%.6f dropped=%u",
           kEngineABI, g_eng->srate(), g_eng->last_block_frames(),
           (long long)g_eng->clock_now(),
           (long long)g_eng->block_index(),
           g_eng->active_voices(), g_eng->owned_voices(),
           g_eng->pool().loaded_count(),
           (double)g_eng->pool().bytes_resident() / (1024.0 * 1024.0),
           nports, g_hook_on ? 1 : 0, (long long)calls, maxgap,
           g_eng->dropped_commands());
  return buf;
}


// ---------------------------------------------------------------------------
// LES LANES MIDI (ABI 1.6)
//
// C'est la surface qui remplace gmem. Le JSFX et Lua se parlaient par un bloc
// de memoire partagee dont les deux cotes recopiaient la carte a la main : une
// constante fausse d'un cote et le symptome ressemblait a un bug de Lua. Ici la
// forme est verifiee par le compilateur d'un cote et par le nom de la fonction
// de l'autre.
//
// LES NOTES S'ECRIVENT EN ENTIER, PUIS SE PUBLIENT. Le moteur tient deux
// tampons par lane et n'en lit qu'un ; CP_LaneSetNote remplit celui qui dort,
// CP_LanePublish echange les deux. Consequence a ne pas oublier : le tampon qui
// dort contient l'avant-derniere version, donc un appelant qui n'ecrirait que
// la note modifiee publierait la liste d'avant avec une note neuve dedans.
// On ecrit tout, on publie une fois — c'est ce que fait un editeur de toute
// facon, et c'est ce qui rend la publication atomique pour le fil audio.
// ---------------------------------------------------------------------------

static bool lane_ok(int lane) { return g_eng && lane >= 0 && lane < kMaxLanes; }

int CP_LaneCount() { return g_eng ? kMaxLanes : 0; }

// Ou parle cette lane. `port` est un port du moteur — le meme objet qu'une
// case audio verse dans une piste — et c'est ce qui fait disparaitre la piste
// routeur : chaque lane ecrit dans SA destination, pre-FX, sans envoi filtre
// et sans budget de seize canaux a partager.
bool CP_LaneBind(int lane, int port, int channel) {
  if (!lane_ok(lane)) return false;
  Lane& L = g_eng->lanes().lane(lane);
  L.port.store((port >= 0 && port < kMaxPorts) ? port : -1,
               std::memory_order_relaxed);
  L.channel.store(channel & 0x0F, std::memory_order_relaxed);
  return true;
}

// param : bars | mute | tag
bool CP_LaneSet(int lane, const char* param, double value) {
  if (!lane_ok(lane) || !param) return false;
  Lane& L = g_eng->lanes().lane(lane);
  if (!strcmp(param, "bars"))  { L.bars.store(value > 0.0 ? value : 1.0, std::memory_order_relaxed); return true; }
  if (!strcmp(param, "mute"))  { L.muted.store(value != 0.0 ? 1 : 0, std::memory_order_relaxed); return true; }
  if (!strcmp(param, "tag"))   { L.tag.store(value, std::memory_order_relaxed); return true; }
  return false;
}

// param : mode | pending | target | phase | lenbeats | tag | nev | recgen
double CP_LaneGet(int lane, const char* param) {
  if (!lane_ok(lane) || !param) return 0.0;
  const Lane& L = g_eng->lanes().lane(lane);
  if (!strcmp(param, "mode"))     return (double)L.mode.load(std::memory_order_relaxed);
  if (!strcmp(param, "pending"))  return (double)L.pending.load(std::memory_order_relaxed);
  if (!strcmp(param, "target"))   return L.pend_target.load(std::memory_order_relaxed);
  if (!strcmp(param, "phase"))    return L.phase.load(std::memory_order_relaxed);
  if (!strcmp(param, "lenbeats")) return L.len_beats.load(std::memory_order_relaxed);
  if (!strcmp(param, "tag"))      return L.tag.load(std::memory_order_relaxed);
  if (!strcmp(param, "nev"))      return (double)g_eng->lanes().note_count(lane);
  if (!strcmp(param, "recgen"))   return (double)L.rec_gen.load(std::memory_order_relaxed);
  if (!strcmp(param, "bars"))     return L.bars.load(std::memory_order_relaxed);
  if (!strcmp(param, "mute"))     return L.muted.load(std::memory_order_relaxed) ? 1.0 : 0.0;
  if (!strcmp(param, "port"))     return (double)L.port.load(std::memory_order_relaxed);
  return 0.0;
}

// 1 rec · 2 stop-rec · 3 clear · 4 panic · 5 play · 6 stop · 7 clear-all ·
// 8 overdub · 9 set-mode (arg = le mode). Tout ce qui est ecrit avant le bloc
// suivant est draine ENSEMBLE : un geste est un bloc, et un echange de clip ou
// une scene entiere tombent du meme cote de la frontiere de quantize.
bool CP_LaneCmd(int lane, int cmd, double arg) {
  if (!g_eng) return false;
  return g_eng->lanes().post(lane, cmd, arg);
}

bool CP_LaneSetNote(int lane, int i, double start, double len,
                           int pitch, int vel) {
  if (!lane_ok(lane) || i < 0 || i >= kMaxLaneNotes) return false;
  LaneNote* b = g_eng->lanes().write_buf(lane);
  if (!b) return false;
  b[i].start = (float)(start > 0.0 ? start : 0.0);
  b[i].len   = (float)(len > 0.0 ? len : 0.0);
  b[i].pitch = (unsigned char)(pitch < 0 ? 0 : (pitch > 127 ? 127 : pitch));
  b[i].vel   = (unsigned char)(vel < 1 ? 1 : (vel > 127 ? 127 : vel));
  return true;
}

bool CP_LanePublish(int lane, int count) {
  if (!lane_ok(lane)) return false;
  g_eng->lanes().publish_notes(lane, count);
  return true;
}

bool CP_LaneGetNote(int lane, int i, double* startOut, double* lenOut,
                           double* pitchOut, double* velOut) {
  if (!lane_ok(lane) || i < 0) return false;
  const LaneNote* b = g_eng->lanes().read_buf(lane);
  if (!b || i >= g_eng->lanes().note_count(lane)) return false;
  if (startOut) *startOut = b[i].start;
  if (lenOut)   *lenOut   = b[i].len;
  if (pitchOut) *pitchOut = b[i].pitch;
  if (velOut)   *velOut   = b[i].vel;
  return true;
}

// L'ANCRE DE TRANSPORT. A poser une fois par frame, comme CP_ClockSync — et
// pour la meme raison : le fil audio ne demande jamais l'heure, il compte ses
// echantillons et cette ancre lui dit une fois ou il en est. Les deux lectures
// (position et horloge) sont collees l'une a l'autre, donc l'erreur vaut le
// temps entre elles, pas une frame de defer.
void CP_TransportSync(double tempo, double beat, int playing,
                             double tsNum) {
  if (!g_eng) return;
  g_eng->lanes().publish_transport(tempo, beat, playing, tsNum,
                                   g_eng->clock_now());
}

void   CP_SetFreeRun(bool on) { if (g_eng) g_eng->lanes().set_freerun(on); }
bool   CP_GetFreeRun()        { return g_eng && g_eng->lanes().freerun(); }
void   CP_SetLaunchQ(double beats) { if (g_eng) g_eng->lanes().set_launch_q(beats); }
double CP_GetLaunchQ()        { return g_eng ? g_eng->lanes().launch_q() : 0.0; }
void   CP_SetAudioRun(bool on) { if (g_eng) g_eng->lanes().set_audio_run(on); }
double CP_EngineBeat()        { return g_eng ? g_eng->lanes().engine_beat() : 0.0; }
bool   CP_ClockRunning()      { return g_eng && g_eng->lanes().clock_running(); }
void   CP_LanesPanic()        { if (g_eng) g_eng->lanes().post(0, kLcPanic, 0.0); }

const char* CP_LanesDiag() {
  static char buf[256];
  if (!g_eng) { snprintf(buf, sizeof(buf), "moteur absent"); return buf; }
  Lanes& L = g_eng->lanes();
  int playing = 0, rec = 0;
  for (int i = 0; i < kMaxLanes; ++i) {
    const int m = L.lane(i).mode.load(std::memory_order_relaxed);
    if (m == kLanePlaying || m == kLaneOverdub) ++playing;
    if (m == kLaneRec) ++rec;
  }
  snprintf(buf, sizeof(buf),
           "lanes=%d jouent=%d capturent=%d beat=%.3f horloge=%s q=%.3f perdues=%u",
           (int)kMaxLanes, playing, rec, L.engine_beat(),
           L.clock_running() ? "oui" : "non", L.launch_q(),
           (unsigned)L.dropped_commands());
  return buf;
}

} // extern "C"

// ---------------------------------------------------------------------------
// Emballages vararg pour ReaScript.
//
// Convention du SDK : un entier passe en (void*)(INT_PTR), un double en
// pointeur vers un double, un pointeur tel quel. Le retour suit la meme regle.
// Le double de retour vit dans un thread_local : l'appelant le copie
// immediatement, et deux fils ne se marchent pas dessus.
// ---------------------------------------------------------------------------
static thread_local double g_ret;
static void* retd(double v) { g_ret = v; return &g_ret; }
static void* retb(bool v)   { return (void*)(INT_PTR)(v ? 1 : 0); }

static double  argd(void** a, int n, int i) { return (i < n && a[i]) ? *(double*)a[i] : 0.0; }
static int     argi(void** a, int n, int i) { return (i < n) ? (int)(INT_PTR)a[i] : 0; }
static void*   argp(void** a, int n, int i) { return (i < n) ? a[i] : nullptr; }

#define VA(name) static void* va_##name(void** arg, int narg)

VA(CP_EngineABI)  { (void)arg; (void)narg; return retd(CP_EngineABI()); }
VA(CP_Srate)      { (void)arg; (void)narg; return retd(CP_Srate()); }
VA(CP_ClockNow)   { (void)arg; (void)narg; return retd(CP_ClockNow()); }
VA(CP_ClockSync)  { (void)arg; (void)narg; return retd(CP_ClockSync()); }
VA(CP_Panic)      { (void)arg; (void)narg; CP_Panic(); return nullptr; }

VA(CP_ClipLoad)   { return retd(CP_ClipLoad((const char*)argp(arg, narg, 0))); }
VA(CP_ClipUnload) { CP_ClipUnload(argd(arg, narg, 0)); return nullptr; }
VA(CP_ClipInfo)   {
  return retb(CP_ClipInfo(argd(arg, narg, 0), (double*)argp(arg, narg, 1),
                          (double*)argp(arg, narg, 2), (double*)argp(arg, narg, 3)));
}
VA(CP_PortAttach) { return retb(CP_PortAttach((MediaTrack*)argp(arg, narg, 0), argi(arg, narg, 1))); }
VA(CP_PortAttachOut) { return retb(CP_PortAttachOut(argi(arg, narg, 0), argi(arg, narg, 1))); }
VA(CP_PortActive) { return retb(CP_PortActive(argi(arg, narg, 0))); }
VA(CP_PortDetach) { CP_PortDetach(argi(arg, narg, 0)); return nullptr; }
VA(CP_PortGain)   { CP_PortGain(argi(arg, narg, 0), argd(arg, narg, 1)); return nullptr; }
VA(CP_VoiceAlloc) { return retd(CP_VoiceAlloc(argi(arg, narg, 0))); }
VA(CP_VoiceRelease) { CP_VoiceRelease(argd(arg, narg, 0)); return nullptr; }
VA(CP_VoicePlayAtSample) {
  return retb(CP_VoicePlayAtSample(argd(arg, narg, 0), argd(arg, narg, 1),
                                   argd(arg, narg, 2), argi(arg, narg, 3),
                                   argd(arg, narg, 4), argd(arg, narg, 5)));
}
VA(CP_VoiceStopAtSample) {
  return retb(CP_VoiceStopAtSample(argd(arg, narg, 0), argd(arg, narg, 1), argd(arg, narg, 2)));
}
VA(CP_VoiceSet) {
  return retb(CP_VoiceSet(argd(arg, narg, 0), (const char*)argp(arg, narg, 1), argd(arg, narg, 2)));
}
VA(CP_VoiceQueueNext) {
  return retb(CP_VoiceQueueNext(argd(arg, narg, 0), argd(arg, narg, 1), argd(arg, narg, 2)));
}
VA(CP_VoiceState) {
  return retb(CP_VoiceState(argd(arg, narg, 0), (double*)argp(arg, narg, 1),
                            (double*)argp(arg, narg, 2)));
}
VA(CP_TimeToSample) { return retd(CP_TimeToSample(argd(arg, narg, 0))); }
VA(CP_VoiceStartedAt) { return retd(CP_VoiceStartedAt(argd(arg, narg, 0))); }
VA(CP_TestMidiAt) {
  return retb(CP_TestMidiAt(argi(arg, narg, 0), argd(arg, narg, 1),
                            argi(arg, narg, 2), argi(arg, narg, 3),
                            argd(arg, narg, 4)));
}
VA(CP_TestMidiDiag) { (void)arg; (void)narg; return (void*)CP_TestMidiDiag(); }
VA(CP_LoadReset) { (void)arg; (void)narg; CP_LoadReset(); return nullptr; }
VA(CP_LoadDiag)  { (void)arg; (void)narg; return (void*)CP_LoadDiag(); }
VA(CP_WarpProbe) { return (void*)CP_WarpProbe(argd(arg, narg, 0), argi(arg, narg, 1)); }
VA(CP_Diag) { (void)arg; (void)narg; return (void*)CP_Diag(); }

// --- lanes MIDI ---
VA(CP_LaneCount)   { (void)arg; (void)narg; return retd(CP_LaneCount()); }
VA(CP_LaneBind)    { return retb(CP_LaneBind(argi(arg, narg, 0), argi(arg, narg, 1), argi(arg, narg, 2))); }
VA(CP_LaneSet)     { return retb(CP_LaneSet(argi(arg, narg, 0), (const char*)argp(arg, narg, 1), argd(arg, narg, 2))); }
VA(CP_LaneGet)     { return retd(CP_LaneGet(argi(arg, narg, 0), (const char*)argp(arg, narg, 1))); }
VA(CP_LaneCmd)     { return retb(CP_LaneCmd(argi(arg, narg, 0), argi(arg, narg, 1), argd(arg, narg, 2))); }
VA(CP_LaneSetNote) { return retb(CP_LaneSetNote(argi(arg, narg, 0), argi(arg, narg, 1), argd(arg, narg, 2), argd(arg, narg, 3), argi(arg, narg, 4), argi(arg, narg, 5))); }
VA(CP_LanePublish) { return retb(CP_LanePublish(argi(arg, narg, 0), argi(arg, narg, 1))); }
VA(CP_LaneGetNote) { return retb(CP_LaneGetNote(argi(arg, narg, 0), argi(arg, narg, 1), (double*)argp(arg, narg, 2), (double*)argp(arg, narg, 3), (double*)argp(arg, narg, 4), (double*)argp(arg, narg, 5))); }
VA(CP_TransportSync) { CP_TransportSync(argd(arg, narg, 0), argd(arg, narg, 1), argi(arg, narg, 2), argd(arg, narg, 3)); return nullptr; }
VA(CP_SetFreeRun)  { CP_SetFreeRun(argi(arg, narg, 0) != 0); return nullptr; }
VA(CP_GetFreeRun)  { (void)arg; (void)narg; return retb(CP_GetFreeRun()); }
VA(CP_SetLaunchQ)  { CP_SetLaunchQ(argd(arg, narg, 0)); return nullptr; }
VA(CP_GetLaunchQ)  { (void)arg; (void)narg; return retd(CP_GetLaunchQ()); }
VA(CP_SetAudioRun) { CP_SetAudioRun(argi(arg, narg, 0) != 0); return nullptr; }
VA(CP_EngineBeat)  { (void)arg; (void)narg; return retd(CP_EngineBeat()); }
VA(CP_ClockRunning){ (void)arg; (void)narg; return retb(CP_ClockRunning()); }
VA(CP_LanesPanic)  { (void)arg; (void)narg; CP_LanesPanic(); return nullptr; }
VA(CP_LanesDiag)   { (void)arg; (void)narg; return (void*)CP_LanesDiag(); }



// ---------------------------------------------------------------------------
// Enregistrement
// ---------------------------------------------------------------------------
#define REG(name, defstr)                                            \
  rec->Register("API_" #name, (void*)&name);                         \
  rec->Register("APIdef_" #name, (void*)(defstr));                   \
  rec->Register("APIvararg_" #name, (void*)&va_##name)

#define UNREG(name)                                                  \
  rec->Register("-API_" #name, (void*)&name);                        \
  rec->Register("-APIdef_" #name, (void*)"");                        \
  rec->Register("-APIvararg_" #name, (void*)&va_##name)

static void register_all(reaper_plugin_info_t* rec) {
  REG(CP_EngineABI, "double\0\0\0Version de l'ABI du moteur. A verifier AVANT tout autre appel.");
  REG(CP_Srate, "double\0\0\0Taux d'echantillonnage courant du moteur.");
  REG(CP_ClipLoad, "double\0const char*\0path\0Decode un fichier en RAM au taux du moteur. Rend l'identifiant du clip, -1 si illisible, -2 si plus long que le plafond de 64 s.");
  REG(CP_ClipUnload, "void\0double\0clip\0Libere un clip. La memoire n'est rendue qu'apres deux blocs audio.");
  REG(CP_ClipInfo, "bool\0double,double*,double*,double*\0clip,framesOut,srateOut,nchOut\0Renseigne un clip charge.");
  REG(CP_PortAttach, "bool\0MediaTrack*,int\0track,port\0Installe un apercu permanent sur la piste (pre-FX). Idempotent.");
  REG(CP_PortAttachOut, "bool\0int,int\0port,outchan\0Installe un apercu permanent sur la SORTIE MATERIELLE, sans piste. outchan 0 = premiere paire. Idempotent.");
  REG(CP_PortActive, "bool\0int\0port\0Ce port a-t-il une sortie. Une voix ne peut etre allouee que sur un port actif.");
  REG(CP_PortDetach, "void\0int\0port\0Retire l'apercu d'une colonne et reprend ses voix.");
  REG(CP_PortGain, "void\0int,double\0port,gain\0Gain lineaire d'une colonne.");
  REG(CP_VoiceAlloc, "double\0int\0port\0Reserve une voix sur un port. Rend un handle, ou 4294967295.");
  REG(CP_VoiceRelease, "void\0double\0voice\0Rend une voix. Toute commande ulterieure sur ce handle est ignoree.");
  REG(CP_VoicePlayAtSample, "bool\0double,double,double,int,double,double\0voice,clip,atSample,mode,rate,gain\0Rendez-vous EXACT a l'echantillon. mode 0=une fois, 1=boucle.");
  REG(CP_VoiceStopAtSample, "bool\0double,double,double\0voice,atSample,fade\0Coupure datee a l'echantillon. fade en secondes, 0 = nette.");
  REG(CP_VoiceSet, "bool\0double,const char*,double\0voice,param,value\0param: rate gain pan loop_start loop_end fade_in fade_out pos loop. 'pos' postee juste apres un play en devient le point de depart.");
  REG(CP_VoiceQueueNext, "bool\0double,double,double\0voice,nextVoice,xfade\0Enchainement exact : la suivante demarre au frame ou celle-ci s'eteint.");
  REG(CP_VoiceState, "bool\0double,double*,double*\0voice,posOut,stateOut\0Position en frames source et etat (0 libre,1 arme,2 joue,3 s'eteint).");
  REG(CP_VoiceStartedAt, "double\0double\0voice\0Frame absolu du premier echantillon reellement audible, -1 si pas encore demarre. Verite terrain, sans course.");
  REG(CP_ClockNow, "double\0\0\0Frame absolu compte par le fil audio.");
  REG(CP_ClockSync, "double\0\0\0Prend l'ancre horloge<->projet. A appeler une fois par frame.");
  REG(CP_TimeToSample, "double\0double\0projectTime\0Convertit un instant du projet en frame absolu, via la derniere ancre.");
  REG(CP_Panic, "void\0\0\0Eteint toutes les voix en 5 ms.");
  REG(CP_Diag, "const char*\0\0\0Etat du moteur en une ligne. Fil principal uniquement.");
  REG(CP_TestMidiAt, "bool\0int,double,int,int,double\0port,atSample,note,vel,durSamples\0EXPERIMENTAL: depose une note datee dans le flux MIDI du bloc. Sonde uniquement.");
  REG(CP_TestMidiDiag, "const char*\0\0\0EXPERIMENTAL: REAPER fournit-il un midi_events, combien d'evenements remis, exacts, en retard.");
  REG(CP_LoadReset, "void\0\0\0Remet a zero les compteurs de charge (temps fil audio, ratios par port).");
  REG(CP_LoadDiag, "const char*\0\0\0Montee en charge: ports, voix, ratio minimum, part du fil audio consommee.");
  REG(CP_LaneCount, "int   Nombre de lanes MIDI que ce binaire sert.");
  REG(CP_LaneBind, "bool int,int,int lane,port,channel Ou parle cette lane : un port du moteur, et un canal MIDI. port -1 = nulle part.");
  REG(CP_LaneSet, "bool int,const char*,double lane,param,value param: bars mute tag.");
  REG(CP_LaneGet, "double int,const char* lane,param param: mode pending target phase lenbeats tag nev recgen bars mute port.");
  REG(CP_LaneCmd, "bool int,int,double lane,cmd,arg rec 2 stop-rec 3 clear 4 panic 5 play 6 stop 7 clear-all 8 overdub 9 set-mode(arg). Tout ce qui est ecrit avant le bloc suivant est draine ensemble.");
  REG(CP_LaneSetNote, "bool int,int,double,double,int,int lane,i,start,len,pitch,vel Ecrit dans le tampon qui dort. Ecrire TOUTE la liste, puis CP_LanePublish.");
  REG(CP_LanePublish, "bool int,int lane,count Echange les deux tampons : la liste devient visible du fil audio d'un seul coup.");
  REG(CP_LaneGetNote, "bool int,int,double*,double*,double*,double* lane,i,startOut,lenOut,pitchOut,velOut Lit la liste PUBLIEE.");
  REG(CP_TransportSync, "void double,double,int,double tempo,beat,playing,tsNum Ancre de transport. A appeler une fois par frame, comme CP_ClockSync.");
  REG(CP_SetFreeRun, "void int on Horloge libre (1) ou transport de l'hote (0).");
  REG(CP_GetFreeRun, "bool   ");
  REG(CP_SetLaunchQ, "void double beats Quantize de lancement en beats. 0 = agir tout de suite.");
  REG(CP_GetLaunchQ, "double   ");
  REG(CP_SetAudioRun, "void int on Une case audio de Lua sonne : l'horloge libre est le transport de la SESSION.");
  REG(CP_EngineBeat, "double   Position de l'horloge sur laquelle le moteur travaille. Les cibles en attente sont sur cette ligne de temps.");
  REG(CP_ClockRunning, "bool   Y a-t-il une horloge du tout.");
  REG(CP_LanesPanic, "void   Arrete toutes les lanes et relache toutes leurs notes.");
  REG(CP_LanesDiag, "const char*   Etat des lanes en une ligne.");
  REG(CP_WarpProbe, "const char*\0double,int\0tempoRatio,nvoices\0Mesure la latence de l'etireur de REAPER (par impulsion) et son cout par voix. Fil principal.");
}

static void unregister_all(reaper_plugin_info_t* rec) {
  UNREG(CP_EngineABI);   UNREG(CP_Srate);            UNREG(CP_ClipLoad);
  UNREG(CP_ClipUnload);  UNREG(CP_ClipInfo);         UNREG(CP_PortAttach);
  UNREG(CP_PortAttachOut); UNREG(CP_PortActive);
  UNREG(CP_PortDetach);  UNREG(CP_PortGain);         UNREG(CP_VoiceAlloc);
  UNREG(CP_VoiceRelease);UNREG(CP_VoicePlayAtSample);UNREG(CP_VoiceStopAtSample);
  UNREG(CP_VoiceSet);    UNREG(CP_VoiceQueueNext);   UNREG(CP_VoiceState);
  UNREG(CP_ClockNow);    UNREG(CP_ClockSync);        UNREG(CP_TimeToSample);
  UNREG(CP_Panic);       UNREG(CP_Diag);             UNREG(CP_VoiceStartedAt);
  UNREG(CP_TestMidiAt);  UNREG(CP_TestMidiDiag);
  UNREG(CP_LaneCount);   UNREG(CP_LaneBind);      UNREG(CP_LaneSet);
  UNREG(CP_LaneGet);     UNREG(CP_LaneCmd);       UNREG(CP_LaneSetNote);
  UNREG(CP_LanePublish); UNREG(CP_LaneGetNote);   UNREG(CP_TransportSync);
  UNREG(CP_SetFreeRun);  UNREG(CP_GetFreeRun);    UNREG(CP_SetLaunchQ);
  UNREG(CP_GetLaunchQ);  UNREG(CP_SetAudioRun);   UNREG(CP_EngineBeat);
  UNREG(CP_ClockRunning);UNREG(CP_LanesPanic);    UNREG(CP_LanesDiag);
  UNREG(CP_LoadReset);   UNREG(CP_LoadDiag);        UNREG(CP_WarpProbe);
}

extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(
    REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec) {
  (void)hInstance;

  if (!rec) {
    // Dechargement. REAPER passe rec = NULL ici, d'ou le pointeur garde au
    // chargement : sans lui on ne peut plus rien desenregistrer.
    //
    // L'ordre compte, et c'est une barriere, pas une preference : on retire
    // d'abord le hook et les apercus — le fil audio cesse alors de nous appeler
    // — et seulement ensuite on detruit. Dans l'autre sens c'est une course, et
    // elle se manifeste par un plantage de REAPER, pas par un bug.
    if (g_hook_on) { Audio_RegHardwareHook(false, &g_hook); g_hook_on = false; }
    for (int i = 0; i < kMaxPorts; ++i) CP_PortDetach(i);
    if (g_rec) { unregister_all(g_rec); g_rec = nullptr; }
    delete g_eng;
    g_eng = nullptr;
    return 0;
  }

  if (rec->caller_version != REAPER_PLUGIN_VERSION) return 0;
  if (REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;

  g_eng = new (std::nothrow) Engine();
  if (!g_eng) return 0;
  g_eng->init(48000.0);

  memset(g_ports, 0, sizeof(g_ports));

  memset(&g_hook, 0, sizeof(g_hook));
  g_hook.OnAudioBuffer = OnAudioBuffer;
  g_hook_on = (Audio_RegHardwareHook(true, &g_hook) != 0);
  // Si le hook n'est pas disponible, le moteur ne s'arrete pas : un port fait
  // office d'horloge (voir Engine::render_port). Aucun service optionnel ne
  // doit pouvoir empecher le moteur d'exister.

  g_rec = rec;
  register_all(rec);

  ShowConsoleMsg("[CP_Native] moteur charge — CP_EngineABI() disponible\n");
  return 1;
}
