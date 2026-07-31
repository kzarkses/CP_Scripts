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
#include <new>

#include "cp_source.h"
#include "../core/cp_engine.h"

using namespace cp;

// Version de l'ABI. Lua DOIT la verifier avant tout autre appel : ReaPack n'a
// aucun mecanisme de dependance (mesure : 89 index, 5993 paquets, zero element
// de dependance), donc un script peut tres bien s'installer sans le binaire, ou
// avec une version qui ne parle pas la meme langue.
static const double kEngineABI = 1.0;

// ---------------------------------------------------------------------------
// Etat global. Le moteur pese plusieurs centaines de kilo-octets : il vit sur
// le tas, alloue une seule fois au chargement, jamais pendant le jeu.
// ---------------------------------------------------------------------------
static Engine* g_eng = nullptr;

struct Port {
  PortSource*         src;
  preview_register_t  reg;
  bool                active;
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
  if (frames > kMaxClipFrames) frames = kMaxClipFrames; // plafond produit

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
  g_eng->pool().retire((int)clip, g_eng->block_index());
  g_eng->pool().collect(g_eng->block_index());
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

bool CP_PortAttach(MediaTrack* track, int port) {
  if (!g_eng || !track || port < 0 || port >= kMaxPorts) return false;
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
  p.reg.m_out_chan = -1;          // -1 => preview_track est pris en compte
  p.reg.curpos = 0.0;
  p.reg.loop = true;              // ne s'arrete jamais de lui-meme
  p.reg.volume = 1.0;
  p.reg.preview_track = track;

  // measure_align = 0 : c'est NOUS qui datons, a l'echantillon. L'alignement de
  // mesure de REAPER est plus grossier que ce que le moteur sait faire.
  if (!PlayTrackPreview2Ex(0, &p.reg, 0, 0.0)) {
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

void CP_PortDetach(int port) {
  if (port < 0 || port >= kMaxPorts) return;
  Port& p = g_ports[port];
  if (!p.active) return;
  // StopTrackPreview2 rend la main quand l'apercu est retire : a partir de la,
  // ce port ne rend plus. C'est SEULEMENT a ce moment qu'on peut reprendre ses
  // voix de force — sinon une voix en fondu de sortie n'a plus personne pour
  // faire avancer son fondu, et son slot est perdu jusqu'au redemarrage.
  StopTrackPreview2(0, &p.reg);
  if (g_eng) g_eng->port_reset(port);
#ifdef _WIN32
  DeleteCriticalSection(&p.reg.cs);
#endif
  delete p.src;
  p.src = nullptr;
  p.active = false;
}

void CP_PortGain(int port, double gain) {
  if (!g_eng) return;
  Cmd c; memset(&c, 0, sizeof(c));
  c.type = kCmdPortGain; c.at = kNow; c.a = gain; c.u1 = (uint32_t)port;
  g_eng->post(port, c);
}

double CP_VoiceAlloc(int port) {
  if (!g_eng) return (double)kNullVoice;
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

double CP_ClockNow() { return g_eng ? (double)g_eng->clock_now() : 0.0; }

// Prend l'ancre. Les deux lectures sont collees volontairement : tout ce qui se
// glisse entre elles devient de l'erreur.
double CP_ClockSync() {
  if (!g_eng) return 0.0;
  const int64_t s = g_eng->clock_now();
  const double  p = GetPlayPosition();
  g_anchor_smp = s;
  g_anchor_pos = p;
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
           "abi=%.1f srate=%.0f bloc=%d clock=%lld blocks=%lld voices=%d clips=%d "
           "ram=%.2fMo ports=%d hook=%d calls=%lld maxgap=%.6f dropped=%u",
           kEngineABI, g_eng->srate(), g_eng->last_block_frames(),
           (long long)g_eng->clock_now(),
           (long long)g_eng->block_index(), g_eng->active_voices(),
           g_eng->pool().loaded_count(),
           (double)g_eng->pool().bytes_resident() / (1024.0 * 1024.0),
           nports, g_hook_on ? 1 : 0, (long long)calls, maxgap,
           g_eng->dropped_commands());
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
VA(CP_Diag) { (void)arg; (void)narg; return (void*)CP_Diag(); }

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
  REG(CP_ClipLoad, "double\0const char*\0path\0Decode un fichier en RAM au taux du moteur. Rend l'identifiant du clip, ou -1.");
  REG(CP_ClipUnload, "void\0double\0clip\0Libere un clip. La memoire n'est rendue qu'apres deux blocs audio.");
  REG(CP_ClipInfo, "bool\0double,double*,double*,double*\0clip,framesOut,srateOut,nchOut\0Renseigne un clip charge.");
  REG(CP_PortAttach, "bool\0MediaTrack*,int\0track,port\0Installe un apercu permanent sur la piste. Idempotent.");
  REG(CP_PortDetach, "void\0int\0port\0Retire l'apercu d'une colonne.");
  REG(CP_PortGain, "void\0int,double\0port,gain\0Gain lineaire d'une colonne.");
  REG(CP_VoiceAlloc, "double\0int\0port\0Reserve une voix sur un port. Rend un handle, ou 4294967295.");
  REG(CP_VoiceRelease, "void\0double\0voice\0Rend une voix. Toute commande ulterieure sur ce handle est ignoree.");
  REG(CP_VoicePlayAtSample, "bool\0double,double,double,int,double,double\0voice,clip,atSample,mode,rate,gain\0Rendez-vous EXACT a l'echantillon. mode 0=une fois, 1=boucle.");
  REG(CP_VoiceStopAtSample, "bool\0double,double,double\0voice,atSample,fade\0Coupure datee a l'echantillon. fade en secondes, 0 = nette.");
  REG(CP_VoiceSet, "bool\0double,const char*,double\0voice,param,value\0param: rate gain pan loop_start loop_end fade_in fade_out");
  REG(CP_VoiceQueueNext, "bool\0double,double,double\0voice,nextVoice,xfade\0Enchainement exact : la suivante demarre au frame ou celle-ci s'eteint.");
  REG(CP_VoiceState, "bool\0double,double*,double*\0voice,posOut,stateOut\0Position en frames source et etat (0 libre,1 arme,2 joue,3 s'eteint).");
  REG(CP_ClockNow, "double\0\0\0Frame absolu compte par le fil audio.");
  REG(CP_ClockSync, "double\0\0\0Prend l'ancre horloge<->projet. A appeler une fois par frame.");
  REG(CP_TimeToSample, "double\0double\0projectTime\0Convertit un instant du projet en frame absolu, via la derniere ancre.");
  REG(CP_Panic, "void\0\0\0Eteint toutes les voix en 5 ms.");
  REG(CP_Diag, "const char*\0\0\0Etat du moteur en une ligne. Fil principal uniquement.");
}

static void unregister_all(reaper_plugin_info_t* rec) {
  UNREG(CP_EngineABI);   UNREG(CP_Srate);            UNREG(CP_ClipLoad);
  UNREG(CP_ClipUnload);  UNREG(CP_ClipInfo);         UNREG(CP_PortAttach);
  UNREG(CP_PortDetach);  UNREG(CP_PortGain);         UNREG(CP_VoiceAlloc);
  UNREG(CP_VoiceRelease);UNREG(CP_VoicePlayAtSample);UNREG(CP_VoiceStopAtSample);
  UNREG(CP_VoiceSet);    UNREG(CP_VoiceQueueNext);   UNREG(CP_VoiceState);
  UNREG(CP_ClockNow);    UNREG(CP_ClockSync);        UNREG(CP_TimeToSample);
  UNREG(CP_Panic);       UNREG(CP_Diag);
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
