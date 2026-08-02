// CP_Native — le moteur de lanes MIDI.
//
// C'est le portage de CP_MidiLooper.jsfx (phase 6 de la feuille de route), et
// avec lui disparaissent la piste routeur, ses envois filtres par canal, gmem
// comme protocole, et le plafond de quatre colonnes — qui ne venait pas d'un
// MAX_LANES mais du budget de 16 canaux MIDI d'une seule piste.
//
// REGLE DU DOSSIER src/core, tenue ici aussi : aucun appel a l'API REAPER,
// aucune allocation apres l'initialisation, rien qui puisse bloquer. Ce
// fichier se compile et se verifie sans REAPER.
//
// ---------------------------------------------------------------------------
// CE QUI EST DANS LE FIL AUDIO, ET CE QUI N'Y EST PAS
// ---------------------------------------------------------------------------
// Le JSFX faisait tout dans le fil audio parce qu'il n'avait pas le choix.
// Ici on choisit, et le partage suit une seule question : « est-ce que se
// tromper de 30 ms s'entend ? »
//
//   FIL AUDIO    la porte (quelles notes doivent sonner a cet instant), les
//                transitions d'etat en attente (un lancement quantifie tombe
//                sur SA frontiere), et l'horloge libre. Une double-croche a
//                140 BPM dure 107 ms : une frame de defer se serait entendue.
//   FIL PRINCIPAL les notes elles-memes, la capture live, la persistance, le
//                routage, l'interface. Rien de tout cela n'a d'echeance a la
//                milliseconde.
//
// Consequence directe et voulue : LE FIL AUDIO N'ECRIT JAMAIS DE NOTE. Il les
// lit. La capture entre par MIDI_GetRecentInputEvent, cote Lua, ou chaque
// evenement arrive DEJA horodate en echantillons — donc plus precisement que
// ce que le JSFX pouvait faire d'un midirecv par bloc.
//
// ---------------------------------------------------------------------------
// LA LISTE DE NOTES, ET POURQUOI ELLE EST DOUBLE
// ---------------------------------------------------------------------------
// Le JSFX partageait sa liste par gmem : le fil principal ecrivait pendant que
// le fil audio lisait. Benin en pratique, indefini en droit — et ce depot a
// deja paye une fois pour la difference. Chaque lane porte donc DEUX tampons :
// le principal ecrit dans celui qui n'est pas publie, puis publie l'indice
// d'un seul store atomique. Le fil audio prend l'indice une fois en debut de
// bloc et lit ce tampon-la jusqu'au bout. Aucune lecture dechiree, aucun
// verrou, et le prix est un megaoctet.
//
// ---------------------------------------------------------------------------
// OU SORT LE MIDI
// ---------------------------------------------------------------------------
// Une lane parle dans un PORT — le meme objet qu'une case audio utilise, un
// apercu permanent verse dans une piste, en pre-FX. Chaque lane a le sien,
// donc deux lanes ne se partagent plus un canal et le plafond de 16 disparait
// avec la piste qui l'imposait. Les evenements sont dates en echantillons
// ABSOLUS et deposes dans la file du port ; PortSource les rend au bloc dont
// ils relevent, a l'offset exact.
#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include "cp_types.h"
#include "cp_ring.h"

namespace cp {

enum : int {
  // 32 lanes = 16 colonnes et leur jumelle silencieuse. Le plafond n'est plus
  // musical, il est memoire : 32 x 2 x 1024 notes x 12 octets = 786 Ko.
  kMaxLanes     = 32,
  kMaxLaneNotes = 1024,
  // Evenements MIDI en attente par port et par bloc. Une porte qui bascule
  // integralement produit 128 coupures et 128 attaques ; 256 couvre le pire
  // cas sans jamais avoir a en perdre un.
  kPortMidiCap  = 256,
};

// Modes de lane — memes valeurs que le JSFX et que Loop.lua, parce que trois
// couches qui numerotent les memes etats differemment est exactement le genre
// de traduction qu'on oublie une fois.
enum LaneMode : int {
  kLaneEmpty    = 0,
  kLaneRec      = 1,
  kLaneStopped  = 2,
  kLanePlaying  = 3,
  kLaneArmed    = 4,
  kLaneOverdub  = 5,
};

enum LanePending : int {
  kPendNone    = 0,
  kPendPlay    = 1,
  kPendStop    = 2,
  kPendRec     = 3,
  kPendStopRec = 4,
  kPendOverdub = 5,
};

enum LaneCmdType : int {
  kLcRec      = 1,
  kLcStopRec  = 2,
  kLcClear    = 3,
  kLcPanic    = 4,
  kLcPlay     = 5,
  kLcStop     = 6,
  kLcClearAll = 7,
  kLcOverdub  = 8,
  kLcSetMode  = 9,   // rappel de session : poser l'etat sans le jouer
};

// Une cible en attente qui n'a PAS ENCORE DE DATE : elle partira au premier
// bloc ou une horloge existe. Les vraies cibles sont des positions en beats et
// ne sont jamais negatives, donc tout ce qui passe sous kWaitTest est ceci et
// rien d'autre. (Meme convention que le JSFX, aux memes valeurs, pour que
// l'interface qui l'affiche n'ait pas a apprendre un second vocabulaire.)
static const double kWaitClock = -1000000000.0;
static const double kWaitTest  =  -100000000.0;

struct LaneNote {
  float         start;   // en beats depuis le debut de la boucle
  float         len;     // en beats
  unsigned char pitch;
  unsigned char vel;
  // CHANCE DE JOUER, en pourcent, 0..100. Cent = toujours, et c'est le chemin
  // rapide : la porte ne hache rien pour une note qui n'a pas de probabilite,
  // c'est-a-dire pour l'immense majorite d'entre elles.
  //
  // Elle a pris UN DES DEUX OCTETS DE BOURRAGE, donc `sizeof(LaneNote)` ne
  // bouge pas et la liste tient toujours dans le meme megaoctet.
  unsigned char prob;
  unsigned char pad;
};

struct LaneCmd {
  int32_t lane;
  int32_t cmd;
  double  arg;
};

// ---------------------------------------------------------------------------
// L'ancre de transport. Le coeur ne peut pas demander l'heure a REAPER : le
// fil principal la lui depose, et le fil audio la convertit en comptant ses
// echantillons — exactement comme l'ancre d'horloge du moteur de clips.
//
// Ecrite par un seul fil, lue par un seul fil, mais faite de CINQ champs qui
// doivent s'accorder : un compteur de sequence les publie ensemble. Le lecteur
// ne tourne jamais en boucle — s'il tombe au milieu d'une ecriture il garde la
// derniere version coherente, ce qui coute un bloc et jamais un blocage.
// ---------------------------------------------------------------------------
struct Transport {
  std::atomic<uint32_t> seq;
  double  tempo;
  double  beat;       // beat du projet a l'instant `at_frame`
  double  ts_num;
  // La vitesse de lecture maitresse de REAPER. Elle n'est PAS un facteur de
  // tempo : le tempo du projet ne bouge pas, c'est la ligne de temps entiere
  // qui defile plus vite. Consequence pour nous, et c'est la seule : un beat
  // dure `rate` fois moins d'echantillons. Sans elle, un moteur qui compte ses
  // echantillons continue au tempo nominal pendant que le projet accelere, et
  // les deux se separent lineairement.
  double  rate;
  int     playing;
  frame_t at_frame;

  Transport() : seq(0), tempo(120.0), beat(0.0), ts_num(4.0), rate(1.0),
                playing(0), at_frame(0) {}
};

struct Lane {
  // --- fil principal ---------------------------------------------------------
  std::atomic<int>    port;        // -1 = ne parle nulle part
  std::atomic<int>    channel;     // 0..15
  std::atomic<double> bars;        // longueur de boucle, en mesures
  std::atomic<int>    muted;
  std::atomic<double> tag;         // identite du clip que la lane tient
  // LE DECALAGE DE PHASE — « joue a partir d'ici ».
  //
  // La phase d'une lane est ancree sur le beat ZERO du projet : c'est ce qui
  // verrouille toutes les boucles sur la meme grille, et on n'y touche pas.
  // Mais un decalage CONSTANT ne casse pas ce verrou — il le deplace. La lane
  // reste sur la grille, a distance fixe, et rien ne derive : c'est exactement
  // le legato launch d'Ableton, et c'est ce que veut dire « lire a partir
  // d'ici ».
  //
  // Il est lu au MEME endroit par le portail MIDI et par la phase publiee (que
  // lit Cells pour l'audio) : les deux moteurs doivent voir la meme boucle, ou
  // le son et les notes se separeraient d'un decalage exactement egal a celui
  // qu'on vient de poser.
  //
  // DELIBEREMENT NON PERSISTE. C'est un geste de jeu, comme un scrub ; le
  // retrouver a la reouverture d'un projet serait une surprise, pas un service.
  std::atomic<double> phase_off;   // en beats

  // « QUAND CETTE LANE PARTIRA, QU'ELLE PARTE D'ICI. » En beats, ou < 0 pour
  // « rien de demande ».
  //
  // Poser `phase_off` depuis Lua a la place ne peut pas marcher, et le symptome
  // le dit : le clip demarre a l'ANCIEN endroit pendant une frame, puis saute.
  // Lua ne voit le lancement qu'apres coup — le mode a deja bascule, le premier
  // bloc a deja sonne. Et il ne peut pas non plus le PREVOIR : la frontiere de
  // quantize est choisie ici, exactement pour qu'il n'y ait pas deux horloges
  // qui pourraient diverger.
  //
  // On arme donc l'intention, et c'est le moteur qui la consomme a l'instant
  // ou il choisit la frontiere — il connait `tq`, donc le decalage est exact du
  // premier echantillon.
  std::atomic<double> play_from;   // en beats, < 0 = aucun

  // L'ACCOLADE DE BOUCLE — « je ne veux entendre que ces deux mesures-la ».
  //
  // Une sous-region de la case, en beats depuis son debut. `loop_b <= loop_a`
  // veut dire « pas d'accolade », et c'est l'etat de toutes les lanes : une
  // case boucle sur toute sa longueur tant qu'on ne lui a rien demande.
  //
  // CE N'EST PAS UNE PORTE, C'EST UNE LONGUEUR DE BOUCLE, et toute la valeur
  // de la fonctionnalite tient dans cette distinction. Taire les notes du
  // dehors aurait ete plus simple a ecrire : la case aurait continue de
  // tourner sur ses quatre mesures en n'en faisant sonner que deux, donc deux
  // mesures de musique suivies de deux mesures de silence. Le loop brace
  // d'Ableton fait l'autre chose, la seule qui soit musicale : la case DEVIENT
  // une boucle de deux mesures, qui revient deux fois plus souvent.
  //
  // Le verrouillage de phase y survit intact, parce que c'est exactement le
  // meme verrou : une lane de longueur Ls ancree sur le beat zero du projet.
  // On n'a pas ajoute une horloge, on a change une longueur — et c'est pour ca
  // que ce champ ne coute rien au reste du moteur.
  std::atomic<double> loop_a;      // en beats depuis le debut de la case
  std::atomic<double> loop_b;      // <= loop_a : pas d'accolade

  // ---------------------------------------------------------------------------
  // LA SIGNATURE DE LA BOUCLE — 0 = suivre le projet
  // ---------------------------------------------------------------------------
  // La longueur d'une boucle valait `bars * ts_num`, ou `ts_num` etait la
  // signature rythmique A L'ENDROIT OU LA TETE DE LECTURE SE TROUVE. Une seule
  // mesure en 3/4 quelque part dans le projet changeait donc la longueur de
  // TOUTES les lanes au moment ou le transport la traversait — alors que les
  // notes, elles, sont en beats absolus. La musique se decalait toute seule, et
  // rien ne pouvait l'expliquer depuis la fenetre.
  //
  // Une boucle porte donc la sienne. Zero veut dire « suis le projet », ce qui
  // est le comportement d'avant et donc ce que valent tous les projets deja
  // ecrits — la correction ne change rien tant que personne ne s'en sert.
  std::atomic<double> ts_num;

  std::atomic<int>    nbuf;        // tampon de notes PUBLIE (0 ou 1)
  std::atomic<int>    ncount[2];   // nombre de notes de chaque tampon
  // Les notes elles-memes vivent dans UN bloc, alloue une seule fois par
  // Lanes::init et jamais ensuite. Les poser dans la structure aurait mis
  // 786 Ko dans l'Engine, donc sur la pile de tout ce qui en declare un — le
  // harnais s'y est effondre, et une pile qui deborde ne dit pas pourquoi.
  LaneNote*           buf[2];

  // --- fil audio -------------------------------------------------------------
  // Quelle note sonne, par hauteur : indice+1, ou 0. C'est LA structure de la
  // porte, et elle n'appartient qu'au fil audio.
  int16_t             sounding[128];
  double              rec_start;   // beat auquel la prise en cours a commence

  // --- publie par le fil audio, lu par le principal --------------------------
  std::atomic<int>    mode;
  std::atomic<int>    pending;
  std::atomic<double> pend_target;
  std::atomic<double> phase;
  std::atomic<double> len_beats;
  // La zone de lecture EFFECTIVE, apres bornage. Publiee et non recalculee en
  // Lua : une accolade posee sur quatre mesures puis ramenee a une doit rendre
  // la meme reponse des deux cotes, et deux copies de la regle de bornage
  // finiraient par diverger sur le cas ou elle sert — celui ou l'accolade ne
  // tient plus dans la case.
  std::atomic<double> span_a;
  std::atomic<double> span_len;
  // Incremente a CHAQUE debut de prise. C'est ainsi que Lua sait qu'il doit
  // vider la liste : le fil audio ne touche pas aux notes, il dit seulement
  // qu'une nouvelle prise commence.
  std::atomic<uint32_t> rec_gen;

  Lane();
  void reset();
};

// File de sortie MIDI d'un port. Ecrite et lue par le FIL AUDIO seul (tick()
// et GetSamples tournent tous deux dessus), donc sans atomiques : un tableau
// et un compteur. Les evenements portent un frame ABSOLU ; l'hote rend ceux
// qui tombent dans le bloc qu'il est en train de servir.
struct PortMidi {
  frame_t       at[kPortMidiCap];
  unsigned char msg[kPortMidiCap][3];
  int           count;
  PortMidi() : count(0) { std::memset(at, 0, sizeof(at)); std::memset(msg, 0, sizeof(msg)); }
};

class Lanes {
 public:
  Lanes();
  ~Lanes();

  void init(double srate);
  void set_srate(double srate) { if (srate > 1.0) srate_ = srate; }

  // --- fil principal ---------------------------------------------------------
  // `rate` a une valeur par defaut pour que les appelants qui ne connaissent
  // pas la vitesse de lecture — le harnais, et tout ce qui teste le coeur hors
  // REAPER — restent justes sans avoir a la nommer.
  void publish_transport(double tempo, double beat, int playing, double ts_num,
                         frame_t at_frame, double rate = 1.0);
  bool post(int lane, int cmd, double arg);

  void   set_freerun(bool on)   { freerun_.store(on ? 1 : 0, std::memory_order_relaxed); }
  bool   freerun() const        { return freerun_.load(std::memory_order_relaxed) != 0; }
  void   set_launch_q(double b) { launch_q_.store(b, std::memory_order_relaxed); }
  double launch_q() const       { return launch_q_.load(std::memory_order_relaxed); }
  // « Quelque chose A MOI sonne » — dit par un hote qui joue des cases audio,
  // que ce moteur-ci ne voit pas. L'horloge libre est le transport de la
  // SESSION, et il resterait a zero sous un echantillon qui joue.
  void set_audio_run(bool on)   { audio_run_.store(on ? 1 : 0, std::memory_order_relaxed); }

  // Position de l'horloge sur laquelle ce moteur travaille : le beat de l'hote
  // quand il le suit, sa propre horloge libre sinon. Les cibles en attente sont
  // exprimees sur CETTE ligne de temps.
  double engine_beat() const { return pub_beat_.load(std::memory_order_relaxed); }
  bool   clock_running() const { return pub_active_.load(std::memory_order_relaxed) != 0; }

  Lane& lane(int i) { return lanes_[i]; }
  const Lane& lane(int i) const { return lanes_[i]; }

  // Ecriture des notes : le principal remplit le tampon NON publie, puis
  // publie. Rend le tampon a remplir, ou nullptr si la lane est hors bornes.
  LaneNote* write_buf(int lane);
  void      publish_notes(int lane, int count);
  int       note_count(int lane) const;
  const LaneNote* read_buf(int lane) const;

  // --- fil audio -------------------------------------------------------------
  // Un bloc. `clock` est le frame absolu du PREMIER echantillon a produire,
  // `frames` sa longueur. Appele depuis Engine::tick, donc une fois par bloc
  // materiel et jamais par port.
  void tick(frame_t clock, int frames);

  // Rend les evenements du port qui tombent dans [from, to), les retire de la
  // file, et laisse les autres. Rend le nombre ecrit dans out_at/out_msg.
  int drain_midi(int port, frame_t from, frame_t to,
                 frame_t* out_at, unsigned char (*out_msg)[3], int cap);

  // Tout couper, sans laisser une note tenue derriere soi.
  void all_notes_off();

  uint32_t dropped_commands() const { return dropped_.load(std::memory_order_relaxed); }

 private:
  double  lane_len_beats(int li, double ts_num) const;
  // La zone de lecture effective d'une lane : `a` son debut dans la case,
  // `len` sa longueur. Sans accolade, (0, longueur de la case). Tout ce qui
  // LIT la lane passe par ici — un seul endroit sait ce qu'une accolade veut
  // dire, et il est du cote du fil audio qui s'en sert.
  void    lane_span(int li, double ts_num, double* a, double* len) const;
  double  launch_target(double pb, bool active) const;
  double  stop_target(double pb, bool active) const;
  void    emit(int port, frame_t at, unsigned char s, unsigned char d1,
               unsigned char d2);
  void    flush_lane(int li, frame_t at);
  void    drain_cmds(double pb, bool active, double ts_num, frame_t at);
  // Consomme `play_from` : la lane part a `at_beat`, on veut qu'elle y soit a
  // la phase demandee. Appelee partout ou un mode devient « joue ».
  void    take_play_from(int li, double at_beat, double ts_num);
  void    run_pendings(double pb, bool active, double ts_num, frame_t at,
                       double block_beats);
  void    run_gate(double pb, bool active, double ts_num, frame_t at,
                   int frames, double block_beats);

  Lane      lanes_[kMaxLanes];
  LaneNote* note_store_;         // kMaxLanes * 2 * kMaxLaneNotes, alloue a l'init
  PortMidi  pmidi_[kMaxPorts];
  SpscRing<LaneCmd, 64> cmds_;

  Transport tr_;
  Transport tr_cache_;          // fil audio : la derniere version coherente

  std::atomic<int>    freerun_;
  std::atomic<double> launch_q_;
  std::atomic<int>    audio_run_;
  std::atomic<double> pub_beat_;
  std::atomic<int>    pub_active_;
  std::atomic<uint32_t> dropped_;

  double  srate_;
  double  free_beat_;
  int     prev_active_;
  int     prev_freerun_;
  double  last_pb_;
};

} // namespace cp
