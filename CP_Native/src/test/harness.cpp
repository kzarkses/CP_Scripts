// Harnais hors-ligne — le cœur se verifie SANS REAPER.
//
// C'est la piece que le dossier ne prevoyait pas (§12.2 / B4) et sans laquelle
// on debogue a l'aveugle : un point d'arret dans le fil audio affame la carte
// son et rend l'etat observe faux. Ici, tout est deterministe, tout est
// reproductible, et le piege d'allocation prouve la contrainte « zero
// allocation dans le fil audio » au lieu de l'affirmer.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <limits>
#include <new>
#include <atomic>
#include <thread>

#include "../core/cp_engine.h"

using namespace cp;

// ---------------------------------------------------------------------------
// Piege d'allocation
//
// thread_local : depuis qu'un test fait tourner un VRAI second fil, le drapeau
// doit suivre le fil et non le programme. Un booleen global aurait rendu la
// mesure fausse dans les deux sens a la fois.
// ---------------------------------------------------------------------------
static thread_local bool g_in_audio = false;
static std::atomic<int>  g_alloc_in_audio(0);
static std::atomic<long> g_alloc_total(0);

void* operator new(size_t n) {
  if (g_in_audio) g_alloc_in_audio.fetch_add(1, std::memory_order_relaxed);
  g_alloc_total.fetch_add(1, std::memory_order_relaxed);
  void* p = std::malloc(n ? n : 1);
  if (!p) throw std::bad_alloc();
  return p;
}
void* operator new[](size_t n) { return operator new(n); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, size_t) noexcept { std::free(p); }
void operator delete[](void* p, size_t) noexcept { std::free(p); }

// ---------------------------------------------------------------------------
// Micro-cadre de test
// ---------------------------------------------------------------------------
static int g_pass = 0, g_fail = 0;
static const char* g_group = "";

static void group(const char* g) { g_group = g; std::printf("\n-- %s\n", g); }

static void check(bool ok, const char* what) {
  if (ok) { ++g_pass; std::printf("   ok   %s\n", what); }
  else    { ++g_fail; std::printf("   FAIL %s   [%s]\n", what, g_group); }
}

static void check_eq(long long got, long long want, const char* what) {
  if (got == want) { ++g_pass; std::printf("   ok   %s (%lld)\n", what, got); }
  else { ++g_fail; std::printf("   FAIL %s : obtenu %lld, attendu %lld   [%s]\n",
                               what, got, want, g_group); }
}

static void check_near(double got, double want, double tol, const char* what) {
  if (std::fabs(got - want) <= tol) { ++g_pass; std::printf("   ok   %s (%.9f)\n", what, got); }
  else { ++g_fail; std::printf("   FAIL %s : obtenu %.9f, attendu %.9f   [%s]\n",
                               what, got, want, g_group); }
}

// ---------------------------------------------------------------------------
// Fabrique de clips
// ---------------------------------------------------------------------------
// Rampe strictement croissante et jamais nulle : n'importe quel echantillon
// identifie sa propre position dans la source. C'est ce qui permet de verifier
// l'exactitude a l'echantillon plutot que « ca sonne ».
static int make_ramp_clip(Engine& e, frame_t frames, int nch) {
  const int slot = e.pool().acquire();
  if (slot < 0) return -1;
  if (!e.pool().alloc(slot, frames, nch, 48000.0)) return -1;
  sample_t* d = e.pool().writable(slot);
  for (frame_t i = 0; i < frames; ++i)
    for (int ch = 0; ch < nch; ++ch)
      d[(size_t)i * nch + ch] = (sample_t)(i + 1);
  e.pool().publish(slot);
  return slot;
}

// Le moteur pese plusieurs centaines de kilo-octets (les anneaux de commandes,
// les voix, le vivier). Il n'a rien a faire sur la pile — un Engine local
// deborde une pile de 1 Mo. Il vit sur le tas, une fois, au chargement.
struct EBox {
  Engine* e;
  EBox() : e(new Engine()) { e->init(48000.0); }
  ~EBox() { delete e; }
  Engine& operator*() { return *e; }
  Engine* operator->() { return e; }
};

static Cmd mk(uint32_t type, voice_h v, frame_t at) {
  Cmd c; std::memset(&c, 0, sizeof(c));
  c.type = type; c.voice = v; c.at = at;
  return c;
}

// Rend nb blocs de `bs` frames et concatene dans dst (stereo entrelace).
static void run_blocks(Engine& e, int port, sample_t* dst, int nblocks, int bs) {
  g_in_audio = true;
  for (int b = 0; b < nblocks; ++b) {
    // Rendu PUIS tick : l'horloge compte ce qui a ete delivre. C'est l'ordre du
    // hook materiel de REAPER, dont le passage « post » suit le traitement.
    e.render_port(port, dst + (size_t)b * bs * 2, bs, 2);
    e.tick(bs);
  }
  g_in_audio = false;
}

// ---------------------------------------------------------------------------
// 1. Anneau
// ---------------------------------------------------------------------------
static void test_ring() {
  group("anneau SPSC");
  SpscRing<Cmd, 8> r;
  Cmd c = mk(kCmdVoicePlay, 0, 0), o;
  check(!r.pop(o), "vide au depart");
  for (int i = 0; i < 8; ++i) { c.u0 = (uint32_t)i; check(r.push(c), "push"); }
  check(!r.push(c), "refuse quand plein (jamais d'ecrasement silencieux)");
  for (int i = 0; i < 8; ++i) { check(r.pop(o), "pop"); check_eq(o.u0, i, "ordre FIFO"); }
  check(!r.pop(o), "vide a la fin");
  // Enroulement : le compteur doit survivre a plus d'un tour.
  for (int k = 0; k < 100; ++k) { r.push(c); r.pop(o); }
  check_eq(r.size(), 0, "taille apres 100 tours");
}

// ---------------------------------------------------------------------------
// 2. Vivier
// ---------------------------------------------------------------------------
static void test_pool() {
  group("vivier");
  EBox eb; Engine& e = *eb;
  const int s = make_ramp_clip(e, 1000, 2);
  check(s >= 0, "acquisition + allocation");
  check(e.pool().get(s) != nullptr, "visible du fil audio une fois publie");
  check_eq(e.pool().get(s)->frames, 1000, "longueur");
  check_eq(e.pool().loaded_count(), 1, "un clip resident");

  // Un slot en cours de chargement ne doit JAMAIS etre visible du fil audio.
  const int s2 = e.pool().acquire();
  e.pool().alloc(s2, 100, 1, 48000.0);
  check(e.pool().get(s2) == nullptr, "invisible tant que non publie");
  e.pool().publish(s2);
  check(e.pool().get(s2) != nullptr, "visible apres publication");

  // Barriere de dechargement : deux blocs avant liberation.
  e.pool().retire(s2, 10);
  check(e.pool().get(s2) == nullptr, "retire du fil audio immediatement");
  e.pool().collect(11);
  check_eq(e.pool().loaded_count(), 1, "pas encore libere a +1 bloc");
  e.pool().collect(12);
  check(e.pool().bytes_resident() > 0, "le clip vivant est intact");

  // Le plafond de taille est une decision produit, pas un accident.
  const int s3 = e.pool().acquire();
  check(!e.pool().alloc(s3, kMaxClipFrames + 1, 2, 48000.0), "refuse au-dela du plafond");
}

// ---------------------------------------------------------------------------
// 3. Depart exact a l'echantillon
// ---------------------------------------------------------------------------
static void test_onset_exact() {
  group("depart exact a l'echantillon");

  // La question qui justifie tout le projet : le premier echantillon audible
  // tombe-t-il exactement sur le frame demande, quelle que soit la taille de
  // bloc ? On essaie des tailles qui ne divisent pas le rendez-vous.
  const int sizes[] = { 64, 128, 512, 63, 17, 1 };
  for (int si = 0; si < 6; ++si) {
    const int bs = sizes[si];
    EBox eb; Engine& e = *eb;
    const int clip = make_ramp_clip(e, 4096, 2);
    const voice_h v = e.voice_alloc(0);

    const frame_t target = 1000; // ni multiple de 64, ni de 63, ni de 17
    Cmd c = mk(kCmdVoicePlay, v, target);
    c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayOnce;
    e.post(0, c);

    const int nb = (2048 / bs) + 2;
    sample_t* buf = (sample_t*)std::calloc((size_t)nb * bs * 2, sizeof(sample_t));
    run_blocks(e, 0, buf, nb, bs);

    frame_t first = -1;
    for (frame_t i = 0; i < (frame_t)nb * bs; ++i) {
      if (buf[(size_t)i * 2] != 0.0f) { first = i; break; }
    }
    char what[128];
    std::snprintf(what, sizeof(what), "bloc de %d : premier echantillon audible", bs);
    check_eq(first, target, what);

    // Et la matiere doit etre celle de la source, non reechantillonnee.
    std::snprintf(what, sizeof(what), "bloc de %d : valeur bit-exacte a l'attaque", bs);
    check_near(buf[(size_t)target * 2], 1.0, 0.0, what);
    std::snprintf(what, sizeof(what), "bloc de %d : valeur bit-exacte a +100", bs);
    check_near(buf[(size_t)(target + 100) * 2], 101.0, 0.0, what);

    // Et la meme verite, vue de l'interieur : la voix note son propre instant
    // d'attaque. C'est ce que la sonde lit, au lieu de le deduire de
    // (horloge, position) — deduction exposee a une course d'un bloc.
    std::snprintf(what, sizeof(what), "bloc de %d : started_at note par la voix", bs);
    check_eq(e.voice_started_at(v), target, what);

    std::free(buf);
  }
}

// ---------------------------------------------------------------------------
// 4. Boucle sans derive
// ---------------------------------------------------------------------------
static void test_loop_no_drift() {
  group("boucle sans derive");
  EBox eb; Engine& e = *eb;
  const frame_t len = 480; // 10 ms
  const int clip = make_ramp_clip(e, len, 2);
  const voice_h v = e.voice_alloc(0);

  Cmd c = mk(kCmdVoicePlay, v, 0);
  c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayLoop;
  e.post(0, c);

  const int bs = 64;
  const int nb = 1000; // 64000 frames = 133 tours de boucle
  sample_t* buf = (sample_t*)std::calloc((size_t)nb * bs * 2, sizeof(sample_t));
  run_blocks(e, 0, buf, nb, bs);

  // A taux 1.0, l'echantillon au frame N doit valoir (N % len) + 1, pour TOUT N.
  // Un seul echantillon de derive par tour serait invisible a l'oreille au debut
  // et fatal au bout de dix minutes ; ici il est detecte au premier tour.
  int bad = 0;
  frame_t first_bad = -1;
  for (frame_t i = 0; i < (frame_t)nb * bs; ++i) {
    const float want = (float)((i % len) + 1);
    if (buf[(size_t)i * 2] != want) { if (first_bad < 0) first_bad = i; ++bad; }
  }
  check_eq(bad, 0, "aucun echantillon hors phase sur 133 tours");
  if (bad) std::printf("        premiere divergence au frame %lld\n", (long long)first_bad);

  double pos = 0; int st = 0;
  e.voice_query(v, &pos, &st);
  check_eq(st, kVoicePlaying, "la voix tourne toujours");
  std::free(buf);
}

// ---------------------------------------------------------------------------
// 5. Arret date
// ---------------------------------------------------------------------------
static void test_dated_stop() {
  group("arret date");
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 8192, 2);
  const voice_h v = e.voice_alloc(0);

  Cmd c = mk(kCmdVoicePlay, v, 100);
  c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayLoop;
  e.post(0, c);
  Cmd s = mk(kCmdVoiceStop, v, 1500);
  s.a = 0.0; // coupure nette, pas de fondu : on teste la date, pas la douceur
  e.post(0, s);

  const int bs = 64, nb = 60;
  sample_t* buf = (sample_t*)std::calloc((size_t)nb * bs * 2, sizeof(sample_t));
  run_blocks(e, 0, buf, nb, bs);

  frame_t last = -1;
  for (frame_t i = 0; i < (frame_t)nb * bs; ++i)
    if (buf[(size_t)i * 2] != 0.0f) last = i;
  check_eq(last, 1499, "dernier echantillon audible = stop_at - 1");

  double pos = 0; int st = 0;
  e.voice_query(v, &pos, &st);
  check_eq(st, kVoiceIdle, "voix eteinte");
  std::free(buf);
}

// ---------------------------------------------------------------------------
// 6. Enchainement exact
// ---------------------------------------------------------------------------
static void test_chain() {
  group("enchainement exact a l'echantillon");
  EBox eb; Engine& e = *eb;
  const frame_t len = 700;
  const int clipA = make_ramp_clip(e, len, 2);
  const int clipB = make_ramp_clip(e, len, 2);
  const voice_h a = e.voice_alloc(0);
  const voice_h b = e.voice_alloc(0);

  Cmd ca = mk(kCmdVoicePlay, a, 0);
  ca.a = 1.0; ca.b = 1.0; ca.u0 = (uint32_t)clipA; ca.u1 = kPlayOnce;
  e.post(0, ca);

  // B est arme mais sans date : c'est A qui la lui donnera, au frame exact de
  // sa propre extinction.
  Cmd cb = mk(kCmdVoicePlay, b, (std::numeric_limits<frame_t>::max)());
  cb.a = 1.0; cb.b = 1.0; cb.u0 = (uint32_t)clipB; cb.u1 = kPlayOnce;
  e.post(0, cb);

  Cmd q = mk(kCmdVoiceQueue, a, kNow);
  q.u0 = (uint32_t)b; q.a = 0.0;
  e.post(0, q);

  const int bs = 64, nb = 40;
  sample_t* buf = (sample_t*)std::calloc((size_t)nb * bs * 2, sizeof(sample_t));
  run_blocks(e, 0, buf, nb, bs);

  // A occupe [0, len). B doit reprendre exactement a len, sans trou ni
  // recouvrement : buf[len] doit valoir 1 (premier echantillon de B).
  check_near(buf[(size_t)(len - 1) * 2], (double)len, 0.0, "dernier echantillon de A");
  check_near(buf[(size_t)len * 2], 1.0, 0.0, "premier echantillon de B, au frame exact");
  check_near(buf[(size_t)(len + 10) * 2], 11.0, 0.0, "B poursuit correctement");
  std::free(buf);
}

// ---------------------------------------------------------------------------
// 7. Taux et interpolation
// ---------------------------------------------------------------------------
static void test_rate() {
  group("taux de lecture");
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 4096, 2);
  const voice_h v = e.voice_alloc(0);

  Cmd c = mk(kCmdVoicePlay, v, 0);
  c.a = 0.5; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayOnce;
  e.post(0, c);

  const int bs = 64, nb = 20;
  sample_t* buf = (sample_t*)std::calloc((size_t)nb * bs * 2, sizeof(sample_t));
  run_blocks(e, 0, buf, nb, bs);

  // Sur une rampe parfaitement lineaire, Hermite doit rendre la valeur exacte :
  // au frame 2N on lit la source N, donc la valeur N+1.
  check_near(buf[0], 1.0, 1e-4, "frame 0 -> source 0");
  check_near(buf[(size_t)200 * 2], 101.0, 1e-3, "frame 200 -> source 100");
  check_near(buf[(size_t)1000 * 2], 501.0, 1e-3, "frame 1000 -> source 500");
  std::free(buf);
}

// ---------------------------------------------------------------------------
// 7bis. Changement de taux d'echantillonnage en cours de route
// ---------------------------------------------------------------------------
static void test_srate_change() {
  group("changement de taux d'echantillonnage");

  // Un clip decode a 48 kHz, joue par un moteur passe a 24 kHz : la matiere ne
  // bouge pas, c'est la lecture qui doit avancer deux fois plus vite pour que la
  // hauteur soit preservee. Sans ca, le son « reprend correctement mais avec le
  // pitch change » — exactement ce qu'a montre le changement de peripherique.
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 4096, 2);   // stocke a 48000
  const voice_h v = e.voice_alloc(0);

  e.set_srate(24000.0);

  Cmd c = mk(kCmdVoicePlay, v, 0);
  c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayOnce;
  e.post(0, c);

  const int bs = 64, nb = 10;
  sample_t* buf = (sample_t*)std::calloc((size_t)nb * bs * 2, sizeof(sample_t));
  run_blocks(e, 0, buf, nb, bs);

  // A moitie taux de sortie, le frame N doit lire la source 2N -> valeur 2N+1.
  check_near(buf[0], 1.0, 1e-3, "frame 0 -> source 0");
  check_near(buf[(size_t)100 * 2], 201.0, 1e-2, "frame 100 -> source 200");
  check_near(buf[(size_t)300 * 2], 601.0, 1e-2, "frame 300 -> source 600");
  std::free(buf);
}

// ---------------------------------------------------------------------------
// 8. Handles perimes et robustesse
// ---------------------------------------------------------------------------
static void test_handles() {
  group("handles et robustesse");
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 512, 2);
  const voice_h v = e.voice_alloc(0);
  check(e.voice_valid(v), "handle neuf valide");

  e.voice_release(v);
  check(!e.voice_valid(v), "handle libere invalide");

  // Une commande sur un handle perime doit etre ignoree en silence, pas
  // appliquee a la voix qui a recycle le slot. C'est le scenario reel de ce
  // depot : les scripts meurent et redemarrent en permanence.
  Cmd c = mk(kCmdVoicePlay, v, 0);
  c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayLoop;
  e.post(0, c);

  const int bs = 64, nb = 10;
  sample_t* buf = (sample_t*)std::calloc((size_t)nb * bs * 2, sizeof(sample_t));
  run_blocks(e, 0, buf, nb, bs);
  bool silent = true;
  for (frame_t i = 0; i < (frame_t)nb * bs * 2; ++i) if (buf[i] != 0.0f) silent = false;
  check(silent, "commande sur handle perime : ignoree, silence");
  std::free(buf);

  // Un port hors bornes ne doit jamais ecrire.
  check(!e.post(-1, c), "port negatif refuse");
  check(!e.post(kMaxPorts, c), "port hors bornes refuse");
  check(e.voice_alloc(-1) == kNullVoice, "alloc sur port invalide");
}

// ---------------------------------------------------------------------------
// 9. Charge : 32 voix, et le piege d'allocation
// ---------------------------------------------------------------------------
static void test_load_and_alloc_trap() {
  group("charge 32 voix + piege d'allocation");
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 48000, 2);

  for (int i = 0; i < 32; ++i) {
    const voice_h v = e.voice_alloc(i % 8);
    Cmd c = mk(kCmdVoicePlay, v, (frame_t)(i * 7));
    c.a = 1.0 + 0.001 * i; c.b = 0.2; c.u0 = (uint32_t)clip; c.u1 = kPlayLoop;
    e.post(i % 8, c);
  }

  const int bs = 64, nb = 200;
  sample_t buf[64 * 2];
  const int before = g_alloc_in_audio.load();
  g_in_audio = true;
  for (int b = 0; b < nb; ++b) {
    for (int p = 0; p < 8; ++p) e.render_port(p, buf, bs, 2);
    e.tick(bs);
  }
  g_in_audio = false;

  check_eq(g_alloc_in_audio.load() - before, 0,
           "ZERO allocation dans le chemin audio sur 1600 rendus de port");
  check_eq(e.active_voices(), 32, "les 32 voix tournent");
  check_eq(e.dropped_commands(), 0, "aucune commande perdue");
}

// ---------------------------------------------------------------------------
// 9bis. LA PROPRIETE D'UN EMPLACEMENT — la course de reutilisation, fermee
//
// C'etait le defaut connu du moteur, ecrit noir sur blanc dans son README : le
// fil principal remettait a zero une voix que le fil audio pouvait encore
// parcourir. Benin sur x86 par accident d'architecture, piege garanti sur ARM.
//
// Le correctif ne se verifie pas en relisant le code — il se verifie en
// demandant au moteur de faire exactement ce qui cassait.
// ---------------------------------------------------------------------------
static void test_voice_ownership() {
  group("propriete d'un emplacement");
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 48000, 2);

  const voice_h a = e.voice_alloc(0);
  check(a != kNullVoice, "allocation");
  check_eq(e.owned_voices(), 1, "un emplacement possede");
  check_eq(e.voice_port(a), 0, "le port se lit dans le mot de propriete");

  Cmd c = mk(kCmdVoicePlay, a, 0);
  c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayLoop;
  e.post(0, c);

  sample_t buf[64 * 2];
  g_in_audio = true;
  for (int b = 0; b < 4; ++b) { e.render_port(0, buf, 64, 2); e.tick(64); }
  g_in_audio = false;

  double pos = 0; int st = 0;
  check(e.voice_query(a, &pos, &st), "le handle repond");
  check_eq(st, kVoicePlaying, "etat publie en fin de bloc");
  check(pos > 0.0, "position publiee en fin de bloc");

  // Liberation : le handle meurt IMMEDIATEMENT cote fil principal...
  e.voice_release(a);
  check(!e.voice_valid(a), "handle invalide des le retour de release");
  check_eq(e.owned_voices(), 1,
           "l'emplacement reste POSSEDE : le fil audio ne l'a pas encore rendu");

  // ... et c'est tout l'enjeu : une nouvelle allocation ne peut pas tomber
  // dessus tant qu'il sonne. C'est exactement le scenario qui corrompait.
  const voice_h b2 = e.voice_alloc(0);
  check(b2 != kNullVoice, "une autre voix reste disponible");
  check(handle_index(b2) != handle_index(a),
        "un emplacement encore sonnant n'est JAMAIS reattribue");

  // Le fondu de 5 ms consomme (240 frames a 48 kHz), l'emplacement revient.
  g_in_audio = true;
  for (int b = 0; b < 20; ++b) { e.render_port(0, buf, 64, 2); e.tick(64); }
  g_in_audio = false;
  check_eq(e.owned_voices(), 1, "l'emplacement rendu par le fil audio, une fois eteint");
  check_eq(e.port_list_size(0), 1, "et retire de la liste du port");

  // Le plafond par port est ce qui garantit que cette liste ne deborde pas.
  int n = 1;   // b2 est deja la
  while (e.voice_alloc(0) != kNullVoice) ++n;
  check_eq(n, kMaxPortVoices, "plafond par port : refus net, jamais de debordement");
}

// ---------------------------------------------------------------------------
// 9ter. Cycle serre : mille prises et remises, aucune fuite
// ---------------------------------------------------------------------------
static void test_alloc_cycle() {
  group("mille cycles prise/remise");
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 480, 2);
  sample_t buf[64 * 2];

  for (int i = 0; i < 1000; ++i) {
    const voice_h v = e.voice_alloc(1);
    if (v == kNullVoice) { check(false, "allocation impossible en cours de cycle"); break; }
    Cmd c = mk(kCmdVoicePlay, v, kNow);
    c.a = 1.0; c.b = 0.5; c.u0 = (uint32_t)clip; c.u1 = kPlayOnce;
    e.post(1, c);
    g_in_audio = true;
    e.render_port(1, buf, 64, 2); e.tick(64);
    g_in_audio = false;
    e.voice_release(v);
    g_in_audio = true;
    for (int b = 0; b < 6; ++b) { e.render_port(1, buf, 64, 2); e.tick(64); }
    g_in_audio = false;
  }
  check_eq(e.owned_voices(), 0, "aucun emplacement fuit sur mille cycles");
  check_eq(e.port_list_size(1), 0, "aucune entree orpheline dans la liste du port");
  check_eq(e.dropped_commands(), 0, "aucune commande perdue");
}

// ---------------------------------------------------------------------------
// 9ter-bis. La matiere disparait sous la voix
//
// Trouve en concevant la sonde de session longue, pas en relisant le code : une
// fenetre qui recharge ses clips pendant qu'ils sonnent retire la matiere sous
// une voix vivante. Celle-ci ne pouvait plus rien produire, donc son fondu
// n'avancait plus, donc elle n'atteignait jamais l'etat eteint, donc son
// emplacement n'etait jamais rendu. Le symptome serait arrive une heure plus
// tard, sous la forme « il n'y a plus de voix », et on l'aurait cherche
// n'importe ou sauf ici.
// ---------------------------------------------------------------------------
static void test_clip_pulled_under_voice() {
  group("le clip disparait pendant que la voix le joue");
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 48000, 2);
  const voice_h v = e.voice_alloc(2);

  Cmd c = mk(kCmdVoicePlay, v, 0);
  c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayLoop;
  e.post(2, c);

  sample_t buf[64 * 2];
  g_in_audio = true;
  for (int b = 0; b < 4; ++b) { e.render_port(2, buf, 64, 2); e.tick(64); }
  g_in_audio = false;

  int st = 0;
  e.voice_query(v, nullptr, &st);
  check_eq(st, kVoicePlaying, "la voix joue");

  // Le clip est retire : des le bloc suivant, il n'est plus visible du fil audio.
  e.pool().retire(clip, e.block_index());

  g_in_audio = true;
  for (int b = 0; b < 2; ++b) { e.render_port(2, buf, 64, 2); e.tick(64); }
  g_in_audio = false;

  e.voice_query(v, nullptr, &st);
  check_eq(st, kVoiceIdle, "la voix s'eteint au lieu de rester vivante a jamais");

  // Et surtout : son emplacement revient.
  e.voice_release(v);
  g_in_audio = true;
  for (int b = 0; b < 4; ++b) { e.render_port(2, buf, 64, 2); e.tick(64); }
  g_in_audio = false;
  check_eq(e.owned_voices(), 0, "l'emplacement est rendu, pas perdu");

  // Et la memoire aussi, une fois la barriere de deux blocs franchie.
  e.pool().collect(e.block_index());
  check_eq(e.pool().loaded_count(), 0, "le clip est libere");
}

// ---------------------------------------------------------------------------
// LE RETRAIT EST UNE DEMANDE, PAS UN GESTE
// ---------------------------------------------------------------------------
// Le test precedent decrit le PLANCHER : si quelque chose retire brutalement,
// la voix meurt proprement et l'emplacement revient. Celui-ci decrit ce qui doit
// arriver en usage normal — le clip est demande au retrait pendant qu'une voix
// le joue, et il NE BOUGE PAS. C'est la difference entre « un changement de mode
// tempo coupe le son » et « un changement de mode tempo attend la fin ».
//
// Le compte de references se DEDUIT de ce que les voix publient : c'est
// `refresh_clip_refs` qui le rafraichit, et son absence est exactement ce qui
// rendait le garde-fou du vivier mort depuis toujours.
static void test_retire_waits_for_the_voice() {
  group("la matiere ne se retire pas sous une voix qui la joue");
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 48000, 2);
  const voice_h v = e.voice_alloc(2);

  Cmd c = mk(kCmdVoicePlay, v, 0);
  c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayLoop;
  e.post(2, c);

  sample_t buf[64 * 2];
  g_in_audio = true;
  for (int b = 0; b < 4; ++b) { e.render_port(2, buf, 64, 2); e.tick(64); }
  g_in_audio = false;

  int st = 0;
  e.voice_query(v, nullptr, &st);
  check_eq(st, kVoicePlaying, "la voix joue");

  // LE CHEMIN NORMAL : on recompte avant de demander le retrait.
  e.refresh_clip_refs();
  e.pool().collect(e.block_index());
  e.pool().retire(clip, e.block_index());

  g_in_audio = true;
  for (int b = 0; b < 8; ++b) { e.render_port(2, buf, 64, 2); e.tick(64); }
  g_in_audio = false;

  e.voice_query(v, nullptr, &st);
  check_eq(st, kVoicePlaying, "la voix joue TOUJOURS : rien ne lui a ete retire");
  check_eq(e.pool().loaded_count(), 1, "et la matiere est toujours residente");

  // La voix s'arrete. La demande est alors honoree — et sans elle, le clip
  // serait reste resident jusqu'a la fermeture : une fuite avec un drapeau.
  Cmd st_cmd = mk(kCmdVoiceStop, v, 0);
  e.post(2, st_cmd);
  g_in_audio = true;
  for (int b = 0; b < 8; ++b) { e.render_port(2, buf, 64, 2); e.tick(64); }
  g_in_audio = false;

  e.refresh_clip_refs();
  e.pool().collect(e.block_index());   // honore la demande : masque, barriere
  g_in_audio = true;
  for (int b = 0; b < 4; ++b) { e.render_port(2, buf, 64, 2); e.tick(64); }
  g_in_audio = false;
  e.pool().collect(e.block_index());   // barriere franchie : la memoire rendue

  check_eq(e.pool().loaded_count(), 0, "une fois la voix eteinte, la demande est honoree");
  e.voice_release(v);
}

// ---------------------------------------------------------------------------
// 9quater. DEUX FILS — l'instrument qui rend la course impossible a nier
//
// Un raisonnement sur les barrieres memoire ne prouve rien : c'est exactement le
// genre d'affirmation que ce projet a deja vue infirmee cinq fois par la mesure.
// Ici, un vrai fil audio rend pendant qu'un vrai fil principal prend et rend des
// emplacements aussi vite qu'il peut, en envoyant au passage des commandes sur
// des handles deja perimes.
// ---------------------------------------------------------------------------
static void test_two_threads() {
  group("deux fils, un demi-million d'occasions de se marcher dessus");
  EBox eb; Engine& e = *eb;
  const int clip = make_ramp_clip(e, 4800, 2);

  std::atomic<bool> stop(false);
  std::atomic<long long> blocks(0);
  const int kPorts = 4;

  std::thread audio([&] {
    g_in_audio = true;                 // le piege d'allocation suit CE fil
    sample_t buf[128 * 2];
    while (!stop.load(std::memory_order_relaxed)) {
      for (int p = 0; p < kPorts; ++p) e.render_port(p, buf, 128, 2);
      e.tick(128);
      blocks.fetch_add(1, std::memory_order_relaxed);
    }
    g_in_audio = false;
  });

  const long long kIter = 500000;
  long long allocs = 0, refused = 0;
  for (long long it = 0; it < kIter; ++it) {
    const int port = (int)(it & (kPorts - 1));
    const voice_h v = e.voice_alloc(port);
    if (v == kNullVoice) { ++refused; std::this_thread::yield(); continue; }
    ++allocs;

    Cmd c = mk(kCmdVoicePlay, v, kNow);
    c.a = 1.0; c.b = 0.02; c.u0 = (uint32_t)clip;
    c.u1 = (it & 1) ? kPlayLoop : kPlayOnce;
    e.post(port, c);

    e.voice_release(v);

    // Et le scenario reel de ce depot : un script mort continue d'ecrire. La
    // commande porte un handle deja rendu ; elle ne doit atteindre personne.
    e.post(port, mk(kCmdVoiceStop, v, kNow));
    if ((it & 63) == 0) std::this_thread::yield();
  }

  stop.store(true, std::memory_order_relaxed);
  audio.join();

  check(blocks.load() > 0, "le fil audio a bien tourne");
  check(allocs > 0, "des allocations ont abouti");

  // Le fil audio est arrete : on peut maintenant regarder l'etat interne. On
  // draine ce qui reste, puis on exige le compte rond.
  g_in_audio = true;
  sample_t buf[128 * 2];
  for (int b = 0; b < 200; ++b) {
    for (int p = 0; p < kPorts; ++p) e.render_port(p, buf, 128, 2);
    e.tick(128);
  }
  g_in_audio = false;

  check_eq(e.owned_voices(), 0, "aucun emplacement fuit apres la tempete");
  int orphans = 0;
  for (int p = 0; p < kPorts; ++p) orphans += e.port_list_size(p);
  check_eq(orphans, 0, "aucune entree orpheline dans les listes de port");
  check_eq(e.active_voices(), 0, "plus aucune voix vivante");
  check_eq(g_alloc_in_audio.load(), 0,
           "ZERO allocation dans le fil audio, sous concurrence reelle");

  std::printf("        %lld blocs rendus, %lld allocations, %lld refus (port plein)\n",
              (long long)blocks.load(), allocs, refused);
}

// ---------------------------------------------------------------------------
// 9quinquies. Deplacement de tete et boucle a la volee
// ---------------------------------------------------------------------------
static void test_seek_and_live_loop() {
  group("tete de lecture et boucle a la volee");
  {
    // « pos » postee juste apres un play en devient le point de depart :
    // l'anneau est FIFO, donc les deux commandes tombent dans le meme bloc, dans
    // l'ordre d'ecriture. C'est ce dont un navigateur a besoin pour lancer un
    // fichier depuis un clic dans la forme d'onde.
    EBox eb; Engine& e = *eb;
    const int clip = make_ramp_clip(e, 4096, 2);
    const voice_h v = e.voice_alloc(0);
    Cmd c = mk(kCmdVoicePlay, v, 0);
    c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayOnce;
    e.post(0, c);
    Cmd s = mk(kCmdVoiceSet, v, kNow);
    s.u0 = kParamPos; s.a = 500.0;
    e.post(0, s);

    const int bs = 64, nb = 8;
    sample_t* buf = (sample_t*)std::calloc((size_t)nb * bs * 2, sizeof(sample_t));
    run_blocks(e, 0, buf, nb, bs);
    check_near(buf[0], 501.0, 0.0, "le premier echantillon est la source 500");
    check_near(buf[(size_t)10 * 2], 511.0, 0.0, "et la suite s'enchaine");
    std::free(buf);
  }
  {
    // Une boucle enclenchee PENDANT la lecture ne doit pas faire repartir du
    // debut : elle change ce qui se passe a la fin de la matiere, rien d'autre.
    EBox eb; Engine& e = *eb;
    const frame_t len = 300;
    const int clip = make_ramp_clip(e, len, 2);
    const voice_h v = e.voice_alloc(0);
    Cmd c = mk(kCmdVoicePlay, v, 0);
    c.a = 1.0; c.b = 1.0; c.u0 = (uint32_t)clip; c.u1 = kPlayOnce;
    e.post(0, c);
    Cmd s = mk(kCmdVoiceSet, v, kNow);
    s.u0 = kParamLoop; s.a = 1.0;
    e.post(0, s);

    const int bs = 64, nb = 16;   // 1024 frames = trois tours et des poussieres
    sample_t* buf = (sample_t*)std::calloc((size_t)nb * bs * 2, sizeof(sample_t));
    run_blocks(e, 0, buf, nb, bs);
    check_near(buf[0], 1.0, 0.0, "depart inchange");
    check_near(buf[(size_t)(len + 5) * 2], 6.0, 0.0, "la matiere reboucle");
    check_near(buf[(size_t)(2 * len + 5) * 2], 6.0, 0.0, "et continue de reboucler");
    std::free(buf);
  }
}

// ---------------------------------------------------------------------------
// 10. Horloge
// ---------------------------------------------------------------------------
static void test_clock() {
  group("horloge");
  EBox eb; Engine& e = *eb;
  check_eq(e.clock_now(), 0, "part de zero");
  g_in_audio = true;
  for (int i = 0; i < 100; ++i) e.tick(64);
  g_in_audio = false;
  check_eq(e.clock_now(), 6400, "compte ses echantillons, exactement");
  check_eq(e.block_index(), 100, "compte ses blocs");

  // Sans hook materiel, un port doit pouvoir avancer l'horloge lui-meme :
  // le moteur ne doit jamais dependre d'un service optionnel pour exister.
  EBox eb2; Engine& e2 = *eb2;
  sample_t buf[128 * 2];
  g_in_audio = true;
  for (int i = 0; i < 10; ++i) e2.render_port(0, buf, 128, 2);
  g_in_audio = false;
  check(e2.clock_now() > 0, "l'horloge avance sans hook materiel");
}


// ---------------------------------------------------------------------------
// LE MOTEUR DE LANES MIDI
//
// Ce que ces tests verifient n'est pas « ca sonne » mais l'exactitude a
// l'echantillon de chaque transition, et surtout LA REGLE D'ATTENTE : un
// lancement quantifie tombe sur SA frontiere, ni avant, ni au multiple suivant.
// C'est precisement la faute que le portage Lua des cases audio avait faite, et
// elle avait mis une session entiere a se voir.
// ---------------------------------------------------------------------------
// `prob` vaut 100 par defaut, comme partout ailleurs : un tampon fraichement
// alloue est a zero, et zero veut dire « ne sonne jamais ». Chaque ecrivain de
// note doit donc le poser explicitement, sinon le silence est le defaut.
static void lane_note(Lanes& L, int li, int k, double start, double len,
                      int pitch, int vel, int prob = 100) {
  LaneNote* b = L.write_buf(li);
  b[k].start = (float)start;
  b[k].len   = (float)len;
  b[k].pitch = (unsigned char)pitch;
  b[k].vel   = (unsigned char)vel;
  b[k].prob  = (unsigned char)(prob < 0 ? 0 : (prob > 100 ? 100 : prob));
}

// Le harnais joue le role de PortSource : il vient chercher les evenements du
// bloc que le tick vient de preparer.
struct LaneCap {
  frame_t       at[64];
  unsigned char msg[64][3];
  int           n;
};
static void lane_pull(Lanes& L, int port, frame_t from, int frames, LaneCap* c) {
  c->n = L.drain_midi(port, from, from + frames, c->at, c->msg, 64);
}

static void test_lane_gate() {
  group("lanes : la porte rend les notes du clip");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(true);
  L.set_launch_q(0.0);

  // 120 BPM, 4/4 : un beat = 24000 frames, une mesure = 96000.
  L.publish_transport(120.0, 0.0, 0, 4.0, 0);

  Lane& l0 = L.lane(0);
  l0.port.store(0, std::memory_order_relaxed);
  l0.channel.store(0, std::memory_order_relaxed);
  l0.bars.store(1.0, std::memory_order_relaxed);
  lane_note(L, 0, 0, 0.0, 1.0, 60, 100);   // beat 0, un beat de long
  lane_note(L, 0, 1, 2.0, 1.0, 64, 90);    // beat 2
  L.publish_notes(0, 2);
  L.post(0, kLcSetMode, (double)kLanePlaying);

  LaneCap cap;
  const int B = 512;
  // LE TICK PREPARE LE BLOC SUIVANT. C'est voulu — c'est ce qui permet de dater
  // un evenement a l'echantillon au lieu de le poser a l'offset zero — donc le
  // harnais joue PortSource avec un bloc de decalage, exactement comme REAPER.
  frame_t clk = B;

  e.tick(B);                       // la commande est drainee, la porte ouvre
  lane_pull(L, 0, clk, B, &cap);
  clk += B;
  check_eq(cap.n, 1, "un evenement au premier bloc");
  check_eq(cap.msg[0][0], 0x90, "et c'est une attaque");
  check_eq(cap.msg[0][1], 60, "sur la note ecrite");
  const frame_t on_at = cap.at[0];

  int off_seen = 0;
  for (int i = 0; i < 80 && !off_seen; ++i) {
    e.tick(B);
    lane_pull(L, 0, clk, B, &cap);
    for (int k = 0; k < cap.n; ++k) {
      if (cap.msg[k][0] == 0x80 && cap.msg[k][1] == 60) {
        // CE QU'ON MESURE EST LA DUREE, pas une date absolue : l'horloge libre
        // ne part qu'au bloc ou quelque chose devient occupe, donc l'attaque
        // elle-meme n'est pas a zero. Un beat a 120 BPM vaut 24000 frames, et
        // la coupure doit tomber la — a l'echantillon, pas a la frontiere du
        // bloc, ce que le JSFX ne pouvait pas faire.
        check_near((double)(cap.at[k] - on_at), 24000.0, 2.0,
                   "la note dure exactement un beat, a l'echantillon");
        off_seen = 1;
      }
    }
    clk += B;
  }
  check(off_seen == 1, "la note se coupe d'elle-meme");
}

static void test_lane_launch_quantize() {
  group("lanes : un lancement attend SA frontiere");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(true);
  L.publish_transport(120.0, 0.0, 0, 4.0, 0);
  L.set_launch_q(4.0);                    // une mesure

  Lane& l0 = L.lane(0);
  l0.port.store(0, std::memory_order_relaxed);
  l0.bars.store(1.0, std::memory_order_relaxed);
  lane_note(L, 0, 0, 0.0, 0.5, 60, 100);
  L.publish_notes(0, 1);
  L.post(0, kLcSetMode, (double)kLaneStopped);
  e.tick(512);

  // Rien ne tourne : l'horloge libre est tenue a zero, donc le PREMIER
  // lancement d'une session silencieuse part tout de suite et EST le temps
  // fort. Ce n'est pas un defaut, c'est la regle — et c'est ce qui expliquait
  // le « il demarre tout de suite quoi qu'il arrive » de la session 19.
  L.post(0, kLcPlay, 0.0);
  e.tick(512);
  check_eq(L.lane(0).mode.load(std::memory_order_relaxed), kLanePlaying,
           "le premier lancement d'une session silencieuse part tout de suite");

  Lane& l1 = L.lane(1);
  l1.port.store(1, std::memory_order_relaxed);
  l1.bars.store(1.0, std::memory_order_relaxed);
  lane_note(L, 1, 0, 0.0, 0.5, 67, 100);
  L.publish_notes(1, 1);
  L.post(1, kLcSetMode, (double)kLaneStopped);
  e.tick(512);

  // S'ELOIGNER DE LA FRONTIERE — et de la FENETRE DE TOLERANCE, qui vaut un
  // huitieme du quantize, donc un demi-beat a Q: Bar. Vingt blocs n'en
  // sortaient pas (0,45 beat) : le test passait parce que la fenetre valait
  // 0,05 beat en dur, et il aurait mesure autre chose que ce qu'il annonce.
  for (int i = 0; i < 60; ++i) e.tick(512);
  const double pb = L.engine_beat();
  check(pb > 0.5 && pb < 4.0, "on est au milieu de la mesure");

  L.post(1, kLcPlay, 0.0);
  e.tick(512);
  check_eq(L.lane(1).pending.load(std::memory_order_relaxed), kPendPlay,
           "le second lancement se met en file");
  check_near(L.lane(1).pend_target.load(std::memory_order_relaxed), 4.0, 1e-6,
             "et vise la frontiere de mesure, pas la suivante");
  check_eq(L.lane(1).mode.load(std::memory_order_relaxed), kLaneStopped,
           "il ne joue pas encore");

  int fired = 0;
  for (int i = 0; i < 500 && !fired; ++i) {
    e.tick(512);
    if (L.lane(1).mode.load(std::memory_order_relaxed) == kLanePlaying) fired = 1;
  }
  check(fired == 1, "il part");
  check_near(L.engine_beat(), 4.0, 0.06,
             "et il part A la frontiere, pas une mesure plus loin");

  // LA FENETRE DE TOLERANCE, mesuree.
  //
  // Une main humaine est en retard de 40 a 120 ms. Avec 0,05 beat en dur (25 ms
  // a 120 BPM), un clic qui VISAIT le temps fort tombait derriere lui et
  // partait une mesure plus tard : la case attendait alors que le musicien
  // avait joue juste. La fenetre vaut maintenant un huitieme du quantize, donc
  // un demi-beat a Q: Bar — et un lancement pose a 0,2 beat apres la frontiere
  // appartient encore a celle-ci.
  Lane& l2 = L.lane(2);
  l2.port.store(2, std::memory_order_relaxed);
  l2.bars.store(1.0, std::memory_order_relaxed);
  lane_note(L, 2, 0, 0.0, 0.5, 72, 100);
  L.publish_notes(2, 1);
  L.post(2, kLcSetMode, (double)kLaneStopped);
  e.tick(512);

  // se placer juste APRES la frontiere de la mesure 8 : deux blocs valent
  // 0,043 beat, on en prend cinq pour etre a ~0,1 beat.
  while (L.engine_beat() < 8.0) e.tick(512);
  const double after = L.engine_beat() - 8.0;
  check(after >= 0.0 && after < 0.5, "on est dans la fenetre de tolerance");

  L.post(2, kLcPlay, 0.0);
  e.tick(512);
  check_eq(L.lane(2).mode.load(std::memory_order_relaxed), kLanePlaying,
           "un lancement dans la fenetre part TOUT DE SUITE, pas une mesure plus loin");
}

static void test_lane_loop_and_bounds() {
  group("lanes : boucle, hors-bornes, mute");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(true);
  L.set_launch_q(0.0);
  L.publish_transport(120.0, 0.0, 0, 4.0, 0);

  Lane& l0 = L.lane(0);
  l0.port.store(0, std::memory_order_relaxed);
  l0.bars.store(1.0, std::memory_order_relaxed);     // 4 beats
  lane_note(L, 0, 0, 0.0, 0.5, 60, 100);
  // Une note qui COMMENCE au-dela de la fin de boucle reste stockee —
  // raccourcir une boucle ne doit jamais detruire ce qu'on a ecrit — mais elle
  // ne sonne pas. C'est le repliement qui posait les mesures 2, 3 et 4 sur la
  // premiere.
  lane_note(L, 0, 1, 6.0, 0.5, 72, 100);
  L.publish_notes(0, 2);
  L.post(0, kLcSetMode, (double)kLanePlaying);

  LaneCap cap;
  const int B = 512;
  frame_t clk = B;                 // le tick prepare le bloc suivant
  int ons60 = 0, ons72 = 0;
  // deux tours pleins et pas trois : 8 beats a 120 BPM = 192000 frames, soit
  // 375 blocs de 512. On s'arrete juste avant le troisieme temps fort.
  for (int i = 0; i < 370; ++i) {
    e.tick(B);
    lane_pull(L, 0, clk, B, &cap);
    for (int k = 0; k < cap.n; ++k) {
      if (cap.msg[k][0] == 0x90 && cap.msg[k][1] == 60) ++ons60;
      if (cap.msg[k][0] == 0x90 && cap.msg[k][1] == 72) ++ons72;
    }
    clk += B;
  }
  check_eq(ons60, 2, "la note reboucle une fois par tour");
  check_eq(ons72, 0, "une note hors bornes est gardee mais ne sonne pas");

  l0.muted.store(1, std::memory_order_relaxed);
  for (int i = 0; i < 100; ++i) { e.tick(B); lane_pull(L, 0, clk, B, &cap); clk += B; }
  int on_after = 0;
  for (int i = 0; i < 300; ++i) {
    e.tick(B);
    lane_pull(L, 0, clk, B, &cap);
    for (int k = 0; k < cap.n; ++k) if (cap.msg[k][0] == 0x90) ++on_after;
    clk += B;
  }
  check_eq(on_after, 0, "rien ne repart tant que la lane est muette");
}

// LA VITESSE DE LECTURE DU PROJET RACCOURCIT LE BEAT.
//
// C'est le seul endroit du moteur ou un beat ne vaut pas 60/tempo secondes. En
// SUIVI de transport, la ligne de temps du projet defile `rate` fois plus vite,
// donc le meme beat se parcourt en `rate` fois moins d'echantillons. Le test
// mesure la duree d'une note d'un beat a vitesse 2 : 12000 frames et non 24000.
//
// On teste en suivi et pas en horloge libre, parce que la difference EST la :
// l'horloge libre est le transport de la session et ignore la reglette.
static void test_lane_playrate() {
  group("lanes : la vitesse de lecture raccourcit le beat");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(false);
  L.set_launch_q(0.0);
  // 120 BPM, transport en marche, vitesse 2 : un beat = 12000 frames.
  L.publish_transport(120.0, 0.0, 1, 4.0, 0, 2.0);

  Lane& l0 = L.lane(0);
  l0.port.store(0, std::memory_order_relaxed);
  l0.channel.store(0, std::memory_order_relaxed);
  l0.bars.store(1.0, std::memory_order_relaxed);
  // La note est ecrite au beat 2 et non au beat 0 : l'ancre dit « beat 0 au
  // frame 0 », or le premier tick sert deja le bloc qui commence a 512. Une
  // note au beat 0 serait donc DEJA passee et se ferait repousser au tour
  // suivant — ce qui est le bon comportement, mais ne mesure plus une duree.
  lane_note(L, 0, 0, 2.0, 1.0, 60, 100);
  L.publish_notes(0, 1);
  L.post(0, kLcSetMode, (double)kLanePlaying);

  LaneCap cap;
  const int B = 512;
  frame_t clk = B;

  frame_t on_at = -1;
  int off_seen = 0;
  for (int i = 0; i < 200 && !off_seen; ++i) {
    e.tick(B);
    lane_pull(L, 0, clk, B, &cap);
    for (int k = 0; k < cap.n; ++k) {
      if (cap.msg[k][0] == 0x90 && on_at < 0) on_at = cap.at[k];
      else if (cap.msg[k][0] == 0x80 && on_at >= 0) {
        check_near((double)(cap.at[k] - on_at), 12000.0, 2.0,
                   "un beat a vitesse 2 dure la moitie d'un beat");
        off_seen = 1;
      }
    }
    clk += B;
  }
  check(on_at >= 0, "l'attaque a bien eu lieu");
  check(off_seen == 1, "la note se coupe d'elle-meme");
}

// ---------------------------------------------------------------------------
// LE DECALAGE DE PHASE — « lire a partir d'ici », mesure et non suppose
// ---------------------------------------------------------------------------
// Ce qu'on veut prouver tient en deux points, et le second est celui qui
// compte : (1) la phase publiee se deplace exactement du decalage demande, et
// (2) elle ne DERIVE pas — au bout de plusieurs passes, l'ecart vaut toujours
// la meme chose. C'est toute la difference entre deplacer un verrou de phase et
// le casser, et c'est la seule raison pour laquelle ce champ a le droit
// d'exister.
static void test_lane_phase_offset() {
  group("lanes : le decalage de phase deplace le verrou, il ne le casse pas");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(true);            // l'horloge de la session, qui avance seule
  L.set_launch_q(0.0);
  L.publish_transport(120.0, 0.0, 0, 4.0, 0);

  Lane& a = L.lane(0);            // temoin, sans decalage
  Lane& b = L.lane(1);            // decalee d'un beat
  for (int li = 0; li < 2; ++li) {
    Lane& l = L.lane(li);
    l.port.store(li, std::memory_order_relaxed);
    l.bars.store(1.0, std::memory_order_relaxed);   // 4 beats
    lane_note(L, li, 0, 0.0, 0.5, 60, 100);
    L.publish_notes(li, 1);
    L.post(li, kLcSetMode, (double)kLanePlaying);
  }
  b.phase_off.store(1.0, std::memory_order_relaxed);

  const int B = 512;
  for (int i = 0; i < 4; ++i) e.tick(B);

  const double pa = a.phase.load(std::memory_order_relaxed);
  const double pb = b.phase.load(std::memory_order_relaxed);
  double d = pb - pa;
  d -= std::floor(d / 4.0) * 4.0;
  check_near(d, 1.0, 1e-6, "un beat demande, un beat obtenu");

  // Vingt passes plus loin. Un accumulateur derivant se verrait ici ; un
  // decalage constant, non.
  for (int i = 0; i < 4000; ++i) e.tick(B);
  const double qa = a.phase.load(std::memory_order_relaxed);
  const double qb = b.phase.load(std::memory_order_relaxed);
  double d2 = qb - qa;
  d2 -= std::floor(d2 / 4.0) * 4.0;
  check_near(d2, 1.0, 1e-6, "et il vaut toujours un beat vingt passes plus loin");

  // Remettre a zero fait coincider les deux : le decalage est un DEPLACEMENT,
  // pas un etat qui se serait installe ailleurs.
  b.phase_off.store(0.0, std::memory_order_relaxed);
  e.tick(B);
  check_near(b.phase.load(std::memory_order_relaxed),
             a.phase.load(std::memory_order_relaxed), 1e-6,
             "remis a zero, les deux lanes retombent l'une sur l'autre");
}

// ---------------------------------------------------------------------------
// « QU'ELLE PARTE D'ICI » — arme avant, consomme au lancement
// ---------------------------------------------------------------------------
// Ce qu'on prouve : le decalage est exact DES LE PREMIER BLOC ou la lane joue,
// et il l'est contre la FRONTIERE choisie, pas contre le debut du bloc. C'est
// tout l'objet du champ : pose depuis Lua, il arrivait une frame trop tard et
// le clip demarrait a l'ancien endroit avant de sauter.
static void test_lane_play_from() {
  group("lanes : « qu'elle parte d'ici » est exact des le premier bloc");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(true);
  L.set_launch_q(4.0);           // une frontiere a attendre : le cas qui compte
  L.publish_transport(120.0, 0.0, 0, 4.0, 0);

  Lane& l0 = L.lane(0);
  l0.port.store(0, std::memory_order_relaxed);
  l0.bars.store(1.0, std::memory_order_relaxed);   // 4 beats
  lane_note(L, 0, 0, 0.0, 0.5, 60, 100);
  L.publish_notes(0, 1);
  L.lane(0).mode.store(kLaneStopped, std::memory_order_relaxed);

  l0.play_from.store(3.0, std::memory_order_relaxed);
  L.post(0, kLcPlay, 0.0);

  const int B = 512;
  int guard = 0;
  while (l0.mode.load(std::memory_order_relaxed) != kLanePlaying && guard < 4000) {
    e.tick(B); guard++;
  }
  check(guard < 4000, "la lane a fini par partir");
  // Le champ est CONSOMME : une seconde lecture ne doit pas le reappliquer.
  check_near(l0.play_from.load(std::memory_order_relaxed), -1.0, 1e-9,
             "l'intention est consommee, pas gardee");
  // Et la phase vaut ce qu'on a demande, au bloc pres.
  const double ph = l0.phase.load(std::memory_order_relaxed);
  double d = ph - 3.0;
  d -= std::floor(d / 4.0) * 4.0;
  if (d > 2.0) d -= 4.0;
  check(d >= -0.05 && d <= 0.35,
        "elle est a la phase demandee des le premier bloc joue");
}

// ---------------------------------------------------------------------------
// L'ACCOLADE DE BOUCLE — une longueur, pas une porte
// ---------------------------------------------------------------------------
// Ce qu'on prouve tient dans un COMPTE de notes, et c'est justement ce qui
// separe les deux lectures possibles de « je ne veux entendre que ces deux
// mesures ».
//
// Une PORTE laisserait la case tourner sur ses huit beats en n'en faisant
// sonner que quatre : sur huit beats d'ecoute, chaque note de la zone partirait
// UNE fois. Une LONGUEUR DE BOUCLE fait revenir la zone deux fois plus
// souvent : chaque note part DEUX fois. Le test compte, donc il tranche — alors
// que l'oreille, elle, entend surtout que « ca marche », dans les deux cas.
static void test_lane_loop_brace() {
  group("lanes : l'accolade raccourcit la boucle, elle ne bache pas des notes");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(true);
  L.set_launch_q(0.0);
  L.publish_transport(120.0, 0.0, 0, 4.0, 0);   // un beat = 24000 frames

  Lane& l0 = L.lane(0);
  l0.port.store(0, std::memory_order_relaxed);
  l0.bars.store(2.0, std::memory_order_relaxed);        // 8 beats
  lane_note(L, 0, 0, 0.0, 0.5, 60, 100);
  lane_note(L, 0, 1, 2.0, 0.5, 62, 100);
  lane_note(L, 0, 2, 4.0, 0.5, 64, 100);
  lane_note(L, 0, 3, 6.0, 0.5, 66, 100);
  L.publish_notes(0, 4);

  // La deuxieme moitie de la case, et rien d'autre.
  l0.loop_a.store(4.0, std::memory_order_relaxed);
  l0.loop_b.store(8.0, std::memory_order_relaxed);

  // Un temoin de meme longueur EFFECTIVE, sans accolade : c'est contre lui
  // qu'on verifie que le verrou de grille tient.
  Lane& l1 = L.lane(1);
  l1.port.store(1, std::memory_order_relaxed);
  l1.bars.store(1.0, std::memory_order_relaxed);        // 4 beats
  lane_note(L, 1, 0, 0.0, 0.5, 60, 100);
  L.publish_notes(1, 1);

  L.post(0, kLcSetMode, (double)kLanePlaying);
  L.post(1, kLcSetMode, (double)kLanePlaying);

  const int B = 512;                    // 0,0213333 beat a 120 BPM
  LaneCap cap;
  frame_t clk = 0;
  int on[128];
  for (int p = 0; p < 128; ++p) on[p] = 0;
  double ph_lo = 1e9, ph_hi = -1e9;

  // 370 blocs : 7,89 beat. Juste sous huit, pour que le front du beat 8 tombe
  // hors de la mesure — un test qui compte des fronts doit choisir ses bornes
  // loin d'un front, sinon c'est l'arrondi qu'il mesure.
  for (int i = 0; i < 370; ++i) {
    e.tick(B);
    lane_pull(L, 0, clk, B, &cap);
    for (int k = 0; k < cap.n; ++k) {
      if ((cap.msg[k][0] & 0xF0) == 0x90 && cap.msg[k][2] > 0) {
        on[cap.msg[k][1]]++;
      }
    }
    const double ph = l0.phase.load(std::memory_order_relaxed);
    if (ph < ph_lo) ph_lo = ph;
    if (ph > ph_hi) ph_hi = ph;
    clk += B;
  }

  check(on[60] == 0 && on[62] == 0,
        "ce qui est hors de l'accolade ne sonne pas");
  check(on[64] == 2, "la note du debut de zone revient DEUX fois en huit beats");
  check(on[66] == 2, "celle du milieu de zone aussi");

  // La phase publiee est en coordonnees de CASE : elle vit DANS l'accolade, et
  // c'est ce qui fait que le trait de lecture se dessine au bon endroit et que
  // la voix audio entre dans la bonne partie de la matiere.
  check(ph_lo >= 4.0 - 1e-6, "la phase publiee ne descend pas sous l'accolade");
  check(ph_hi < 8.0 + 1e-6, "et ne monte pas au-dessus");

  // LE VERROU DE GRILLE TIENT. Vingt passes plus loin, l'ecart avec un temoin
  // de meme longueur vaut toujours la meme chose : on a change une longueur,
  // pas ajoute une horloge.
  for (int i = 0; i < 4000; ++i) {
    e.tick(B);
    lane_pull(L, 0, clk, B, &cap);
    lane_pull(L, 1, clk, B, &cap);
    clk += B;
  }
  const double d = l0.phase.load(std::memory_order_relaxed)
                 - l1.phase.load(std::memory_order_relaxed);
  check_near(d, 4.0, 1e-6, "l'accolade reste verrouillee sur la grille");

  // UNE ACCOLADE QUI NE TIENT PLUS DANS LA CASE NE LA FAIT PAS TAIRE. C'est le
  // cas qui arrive vraiment : on la pose sur les mesures 3 et 4, puis on
  // raccourcit la boucle. Le silence serait la pire des reponses, parce que
  // rien dans le geste ne l'a demande — on revient donc a la case entiere.
  l0.loop_a.store(10.0, std::memory_order_relaxed);
  l0.loop_b.store(12.0, std::memory_order_relaxed);
  for (int p = 0; p < 128; ++p) on[p] = 0;
  for (int i = 0; i < 800; ++i) {       // 17 beats : deux passes pleines
    e.tick(B);
    lane_pull(L, 0, clk, B, &cap);
    for (int k = 0; k < cap.n; ++k) {
      if ((cap.msg[k][0] & 0xF0) == 0x90 && cap.msg[k][2] > 0) on[cap.msg[k][1]]++;
    }
    clk += B;
  }
  check(on[60] > 0 && on[62] > 0 && on[64] > 0 && on[66] > 0,
        "hors bornes, on rejoue la case entiere plutot que rien");

  // Et l'effacer rend exactement la case d'avant.
  l0.loop_a.store(0.0, std::memory_order_relaxed);
  l0.loop_b.store(-1.0, std::memory_order_relaxed);
  e.tick(B);
  check_near(l0.span_len.load(std::memory_order_relaxed), 8.0, 1e-9,
             "sans accolade, la zone est la case");
}

// ---------------------------------------------------------------------------
// MODE SUIVI : LA DATE EXACTE D'UNE NOTE, EN ECHANTILLONS
// ---------------------------------------------------------------------------
// Cedric mesure « 45 ms d'avance » sur chaque note. 45 ms a 48 kHz, c'est
// 2160 echantillons — soit, a une poignee pres, UN BLOC de 2048. Un ecart qui
// vaut exactement un bloc ne se discute pas : il se localise. Ce test refait la
// scene avec le bloc qu'il utilise, et il RAPPORTE un nombre plutot qu'un
// « ok » : c'est la mesure qui doit designer le coupable, pas le raisonnement.
static void test_lane_follow_timing() {
  group("lanes : en suivi, une note tombe sur SON echantillon");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(false);           // on SUIT l'hote : c'est le cas de Cedric
  L.set_launch_q(4.0);            // Q : une mesure

  Lane& l0 = L.lane(0);
  l0.port.store(0, std::memory_order_relaxed);
  l0.bars.store(1.0, std::memory_order_relaxed);      // 4 beats = 96000 frames
  lane_note(L, 0, 0, 0.0, 0.5, 60, 100);
  lane_note(L, 0, 1, 1.0, 0.5, 61, 100);
  lane_note(L, 0, 2, 2.0, 0.5, 62, 100);
  lane_note(L, 0, 3, 3.0, 0.5, 63, 100);
  L.publish_notes(0, 4);
  l0.mode.store(kLaneStopped, std::memory_order_relaxed);

  const int B = 2048;             // le bloc qui vaut 42,7 ms
  const double SPB = 24000.0;     // frames par beat a 120 BPM

  LaneCap cap;
  frame_t clk = 0;
  double worst = 0.0;
  int seen = 0;

  for (int i = 0; i < 200; ++i) {
    // L'HOTE PUBLIE SON ANCRE A CHAQUE BLOC, comme Loop.Poll le fait : le beat
    // du projet, et le frame auquel il vaut ca.
    L.publish_transport(120.0, (double)clk / SPB, 1, 4.0, clk, 1.0);
    if (i == 3) L.post(0, kLcPlay, 0.0);

    e.tick(B);
    lane_pull(L, 0, clk, B, &cap);
    for (int k = 0; k < cap.n; ++k) {
      if ((cap.msg[k][0] & 0xF0) == 0x90 && cap.msg[k][2] > 0) {
        // La note de hauteur p commence au beat (p - 60) de la boucle, donc sur
        // la grille du projet toutes les quatre beats.
        double d = (double)cap.at[k] / SPB - (double)(cap.msg[k][1] - 60);
        d -= std::floor(d / 4.0) * 4.0;
        if (d > 2.0) d -= 4.0;                 // ramene dans [-2, +2]
        const double ms = d * 500.0;           // un beat = 500 ms a 120 BPM
        if (seen < 6) {
          std::printf("        note %d : %+.3f ms (%+.0f echantillons)\n",
                      (int)cap.msg[k][1], ms, d * SPB);
        }
        if (std::fabs(ms) > std::fabs(worst)) worst = ms;
        seen++;
      }
    }
    clk += B;
  }

  check(seen > 0, "des notes sont sorties");
  std::printf("        pire ecart : %+.3f ms sur %d notes\n", worst, seen);
  check(std::fabs(worst) < 1.0,
        "aucune note ne s'ecarte d'une milliseconde de son beat");
}

// ---------------------------------------------------------------------------
// L'ARRET DU TRANSPORT, PUIS SA REPRISE
// ---------------------------------------------------------------------------
// « Le clock follow n'attend plus le Q une fois que ca a ete stop une premiere
// fois. » Ce test dit ce que le moteur FAIT, sans prejuger de ce qu'il devrait
// faire : quel mode pendant l'arret, et la note tombe-t-elle toujours sur son
// echantillon a la reprise.
static void test_lane_transport_stop_resume() {
  group("lanes : arret du transport, puis reprise");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(false);
  L.set_launch_q(4.0);

  Lane& l0 = L.lane(0);
  l0.port.store(0, std::memory_order_relaxed);
  l0.bars.store(1.0, std::memory_order_relaxed);
  lane_note(L, 0, 0, 0.0, 0.5, 60, 100);
  L.publish_notes(0, 1);
  l0.mode.store(kLaneStopped, std::memory_order_relaxed);

  const int B = 2048;
  const double SPB = 24000.0;
  LaneCap cap;
  frame_t clk = 0;

  for (int i = 0; i < 60; ++i) {
    L.publish_transport(120.0, (double)clk / SPB, 1, 4.0, clk, 1.0);
    if (i == 3) L.post(0, kLcPlay, 0.0);
    e.tick(B); lane_pull(L, 0, clk, B, &cap); clk += B;
  }
  check(l0.mode.load(std::memory_order_relaxed) == kLanePlaying,
        "la lane joue avant l'arret");
  std::printf("        decalage de phase apres lancement : %.6f beat\n",
              l0.phase_off.load(std::memory_order_relaxed));

  // --- le transport s'arrete, le beat du projet gele -------------------------
  const frame_t stop_at = clk;
  for (int i = 0; i < 30; ++i) {
    L.publish_transport(120.0, (double)stop_at / SPB, 0, 4.0, stop_at, 1.0);
    e.tick(B); lane_pull(L, 0, clk, B, &cap); clk += B;
  }
  std::printf("        pendant l'arret : mode %d, pending %d\n",
              l0.mode.load(std::memory_order_relaxed),
              l0.pending.load(std::memory_order_relaxed));
  // CE QU'ON ATTEND, et non ce qu'on observe : la case reste ALLUMEE mais
  // redevient EN FILE. C'est la difference entre « ce clip est allume » et
  // « ce clip est en train de sonner », et c'est elle qui manquait.
  check(l0.mode.load(std::memory_order_relaxed) == kLaneStopped,
        "l'arret rend la case a l'etat arrete...");
  check(l0.pending.load(std::memory_order_relaxed) == kPendPlay,
        "...mais TOUJOURS EN FILE : allumee, donc entouree et non pleine");
  check_near(l0.phase_off.load(std::memory_order_relaxed), 0.0, 1e-12,
             "et le decalage tombe avec le geste de jeu qui l'avait pose");

  // --- le transport repart d'ou il s'est arrete ------------------------------
  // L'horloge d'echantillons, elle, n'a jamais cesse d'avancer : c'est
  // exactement la situation ou une ancre mal appariee se voit.
  const frame_t resume_clk = clk;
  frame_t first_on = -1;
  for (int i = 0; i < 120; ++i) {
    const double beat = (double)(stop_at + (clk - resume_clk)) / SPB;
    L.publish_transport(120.0, beat, 1, 4.0, clk, 1.0);
    e.tick(B); lane_pull(L, 0, clk, B, &cap);
    for (int k = 0; k < cap.n; ++k) {
      if ((cap.msg[k][0] & 0xF0) == 0x90 && cap.msg[k][2] > 0 && first_on < 0) {
        first_on = cap.at[k];
      }
    }
    clk += B;
  }
  check(first_on >= 0, "la lane rejoue apres la reprise");
  if (first_on >= 0) {
    const double pbeat = (double)(stop_at + (first_on - resume_clk)) / SPB;
    double d = pbeat - std::floor(pbeat / 4.0) * 4.0;
    if (d > 2.0) d -= 4.0;
    std::printf("        premiere note : beat projet %.4f, ecart %+.3f ms\n",
                pbeat, d * 500.0);
    check(std::fabs(d * 500.0) < 1.0, "et elle tombe toujours sur son beat");
    // ET SUR UNE FRONTIERE DE QUANTIZE, pas au bloc qui suit la reprise :
    // c'est toute la plainte — « le clock follow n'attend plus le Q ».
    const double onq = pbeat / 4.0;
    check(std::fabs(onq - std::floor(onq + 0.5)) < 1e-6,
          "la reprise attend la frontiere de quantize");
  }
}

// ---------------------------------------------------------------------------
// LA PROBABILITE PAR NOTE — ce qu'on peut prouver parce que le tirage est
// REPRODUCTIBLE
// ---------------------------------------------------------------------------
// Un vrai generateur aleatoire aurait rendu ce test impossible a ecrire : on
// n'aurait pu verifier qu'une moyenne, sur beaucoup de passes, sans jamais
// savoir si une note s'etait allumee au milieu d'elle-meme. Le hachage de
// (note, passe) permet les trois questions qui comptent :
//
//   1. les BORNES : 100 sonne toujours, 0 ne sonne jamais ;
//   2. la DISTRIBUTION : 50 tombe autour de la moitie des passes ;
//   3. la CONSTANCE : autant de coupures que d'attaques. C'est celle-la qui
//      compte vraiment — une note qui retirerait au sort a mi-chemin laisserait
//      une attaque sans coupure, donc une note tenue jusqu'a la fin des temps.
//
// Et une quatrieme, qui ne se voit qu'a deux lanes : deux lanes portant les
// MEMES notes ne doivent pas tirer a l'identique, sinon ce n'est pas du hasard,
// c'est un motif.
static void test_lane_probability() {
  group("lanes : la probabilite par note, tiree sans un octet d'etat");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(true);
  L.set_launch_q(0.0);
  L.publish_transport(120.0, 0.0, 0, 4.0, 0);   // un beat = 24000 frames

  // Quatre lanes d'une mesure, une note chacune, quatre probabilites.
  const int PROB[4] = { 100, 0, 50, 50 };
  for (int li = 0; li < 4; ++li) {
    Lane& l = L.lane(li);
    l.port.store(li, std::memory_order_relaxed);
    l.bars.store(1.0, std::memory_order_relaxed);       // 4 beats
    // Les lanes 2 et 3 portent EXACTEMENT la meme note : c'est la graine par
    // lane, et rien d'autre, qui doit les separer.
    lane_note(L, li, 0, 0.0, 1.0, 60, 100, PROB[li]);
    L.publish_notes(li, 1);
    L.post(li, kLcSetMode, (double)kLanePlaying);
  }

  const int B  = 512;
  const int NP = 64;                    // 64 passes de 4 beats
  const int NB = (int)(NP * 4.0 * 24000.0 / B);
  LaneCap cap;
  frame_t clk = 0;
  int on[4], off[4];
  for (int i = 0; i < 4; ++i) { on[i] = 0; off[i] = 0; }
  // La suite de decisions de la lane 2, passe par passe, pour la comparer a
  // celle de la lane 3.
  int same = 0, seen = 0;
  int last_on2 = 0, last_on3 = 0;

  for (int i = 0; i < NB; ++i) {
    e.tick(B);
    for (int li = 0; li < 4; ++li) {
      lane_pull(L, li, clk, B, &cap);
      for (int k = 0; k < cap.n; ++k) {
        const int st = cap.msg[k][0] & 0xF0;
        if (st == 0x90 && cap.msg[k][2] > 0) on[li]++;
        else if (st == 0x80 || (st == 0x90 && cap.msg[k][2] == 0)) off[li]++;
      }
    }
    // Un front sur l'une ou l'autre : on compare les deux suites au meme
    // instant, sans avoir a savoir ou tombent les frontieres de passe.
    if (on[2] != last_on2 || on[3] != last_on3) {
      seen++;
      if ((on[2] - last_on2) == (on[3] - last_on3)) same++;
      last_on2 = on[2];
      last_on3 = on[3];
    }
    clk += B;
  }

  check(on[0] >= NP - 1 && on[0] <= NP,
        "prob 100 : la note sonne a chaque passe");
  check(on[1] == 0, "prob 0 : la note ne sonne jamais");
  check(on[2] > NP / 5 && on[2] < (NP * 4) / 5,
        "prob 50 : ni toujours ni jamais");
  std::printf("      prob 50 : %d passes jouees sur %d\n", on[2], NP);

  // LA VRAIE QUESTION. Une decision qui changerait a mi-note laisserait une
  // attaque sans sa coupure — et une note tenue indefiniment est le seul defaut
  // de cette fonctionnalite qui ne se rattrape pas tout seul.
  for (int li = 0; li < 4; ++li) {
    check(off[li] == on[li] || off[li] == on[li] - 1,
          "chaque attaque a sa coupure (la derniere peut etre en vol)");
  }

  // Deux lanes, memes notes, meme probabilite : la graine doit les separer.
  check(seen > 8 && same < seen,
        "deux lanes identiques ne tirent pas la meme suite");
  std::printf("      lanes 2 et 3 : %d fronts, %d en commun\n", seen, same);
}

static void test_lane_no_alloc() {
  group("lanes : zero allocation dans le fil audio");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(true);
  L.set_launch_q(4.0);
  L.publish_transport(120.0, 0.0, 0, 4.0, 0);
  for (int li = 0; li < 8; ++li) {
    Lane& l = L.lane(li);
    l.port.store(li, std::memory_order_relaxed);
    l.bars.store(1.0, std::memory_order_relaxed);
    for (int k = 0; k < 64; ++k) lane_note(L, li, k, k * 0.0625, 0.05, 40 + k, 100);
    // La moitie des lanes porte une accolade : le chemin borne doit passer sous
    // le compteur lui aussi, sans quoi on aurait mesure l'autre.
    if (li < 4) {
      l.loop_a.store(1.0, std::memory_order_relaxed);
      l.loop_b.store(3.0, std::memory_order_relaxed);
    }
    L.publish_notes(li, 64);
    L.post(li, kLcSetMode, (double)kLanePlaying);
  }
  const int before = g_alloc_in_audio.load();
  LaneCap cap;
  frame_t clk = 0;
  g_in_audio = true;
  for (int i = 0; i < 2000; ++i) {
    e.tick(64);
    for (int p = 0; p < 8; ++p) lane_pull(L, p, clk, 64, &cap);
    clk += 64;
  }
  g_in_audio = false;
  check_eq(g_alloc_in_audio.load() - before, 0,
           "2000 blocs, 8 lanes, 512 notes : aucune allocation");
}

static void test_lane_panic_and_clear() {
  group("lanes : panique et vidage ne laissent aucune note tenue");
  Engine e;
  e.init(48000.0);
  Lanes& L = e.lanes();
  L.set_freerun(true);
  L.set_launch_q(0.0);
  L.publish_transport(120.0, 0.0, 0, 4.0, 0);

  Lane& l0 = L.lane(0);
  l0.port.store(0, std::memory_order_relaxed);
  l0.bars.store(1.0, std::memory_order_relaxed);
  lane_note(L, 0, 0, 0.0, 4.0, 60, 100);      // tenue toute la boucle
  L.publish_notes(0, 1);
  L.post(0, kLcSetMode, (double)kLanePlaying);

  LaneCap cap;
  const int B = 512;
  frame_t clk = B;                 // le tick prepare le bloc suivant
  e.tick(B); lane_pull(L, 0, clk, B, &cap); clk += B;
  check_eq(cap.n, 1, "la note tenue attaque");

  L.post(0, kLcPanic, 0.0);
  e.tick(B);
  lane_pull(L, 0, clk, B, &cap);
  clk += B;
  int offs = 0;
  for (int k = 0; k < cap.n; ++k) if (cap.msg[k][0] == 0x80) ++offs;
  check_eq(offs, 1, "la panique relache ce qui sonnait");
  check_eq(L.lane(0).mode.load(std::memory_order_relaxed), kLaneStopped,
           "et arrete la lane sans effacer ses notes");
}

int main() {
  std::printf("CP_Native — harnais hors-ligne du coeur (aucun REAPER requis)\n");
  test_ring();
  test_pool();
  test_onset_exact();
  test_loop_no_drift();
  test_dated_stop();
  test_chain();
  test_rate();
  test_srate_change();
  test_handles();
  test_load_and_alloc_trap();
  test_voice_ownership();
  test_alloc_cycle();
  test_clip_pulled_under_voice();
  test_retire_waits_for_the_voice();
  test_seek_and_live_loop();
  test_two_threads();
  test_clock();
  test_lane_gate();
  test_lane_launch_quantize();
  test_lane_loop_and_bounds();
  test_lane_panic_and_clear();
  test_lane_playrate();
  test_lane_phase_offset();
  test_lane_play_from();
  test_lane_loop_brace();
  test_lane_follow_timing();
  test_lane_transport_stop_resume();
  test_lane_probability();
  test_lane_no_alloc();

  std::printf("\n=====================================\n");
  std::printf("  reussis : %d\n  echecs  : %d\n", g_pass, g_fail);
  std::printf("  allocations totales (init comprise) : %ld\n", g_alloc_total.load());
  std::printf("  allocations dans le fil audio       : %d\n", g_alloc_in_audio.load());
  std::printf("=====================================\n");
  return g_fail ? 1 : 0;
}
