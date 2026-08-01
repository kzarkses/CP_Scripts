// Le moteur : N ports (une colonne = un port), M voix, un vivier, une horloge.
//
// L'horloge est le point delicat de toute l'architecture, et le voici resolu
// explicitement (dossier §12.6, consequence 3) : le fil audio ne DEMANDE jamais
// l'heure, il COMPTE ses echantillons. Une ancre unique, prise sur le fil
// principal, suffit a convertir un instant du projet en frame absolu — et il n'y
// a aucune derive a rattraper, puisque la boucle et le projet sont entraines par
// la meme horloge de carte son (mesure du 2026-07-30).
//
// PARTAGE DE LA PROPRIETE — la regle qui rend le moteur sur :
//
//   fil principal    les mots de propriete (claim_), le vivier, l'horloge-ancre
//   fil audio        les structures Voice, les listes de port, l'horloge
//
// Aucune des deux moities n'ecrit dans l'autre. La seule exception est le bit
// `owned` d'un mot de propriete, que le fil audio EFFACE (et n'ecrit jamais
// autrement) pour dire « j'en ai fini, l'emplacement est reutilisable ».
#pragma once

#include <atomic>
#include "cp_types.h"
#include "cp_ring.h"
#include "cp_pool.h"
#include "cp_voice.h"
#include "cp_lanes.h"

namespace cp {

struct PortState {
  SpscRing<Cmd, kCmdRingCap> cmds;

  // Les voix vivantes de CE port, index dans voices_. Tenue par le FIL AUDIO
  // seul, remplie par kCmdVoiceAlloc, videe par kCmdVoiceFree.
  //
  // Avant elle, chaque rendu de port balayait les 256 voix pour en trouver
  // huit : 40 Ko de structures traversees par port et par bloc, deux fois. La
  // liste ramene le balayage a ce que le port possede reellement.
  int16_t vlist[kMaxPortVoices];
  int     vcount;

  float   gain;
  float   gain_target;
  frame_t last_clock;   // valeur de l'horloge au dernier bloc observe
  int     consumed;     // frames deja rendus dans le bloc courant
  bool    used;

  PortState() : vcount(0), gain(1.0f), gain_target(1.0f), last_clock(-1),
                consumed(0), used(false) {
    for (int i = 0; i < kMaxPortVoices; ++i) vlist[i] = -1;
  }
};

class Engine {
 public:
  Engine();

  // --- fil principal --------------------------------------------------------
  void init(double srate);
  void set_srate(double srate);
  double srate() const { return srate_; }

  Pool& pool() { return pool_; }
  const Pool& pool() const { return pool_; }

  // Reserve une voix sur un port. kNullVoice si plus de place.
  //
  // N'ECRIT PAS dans la voix : pose le mot de propriete, puis demande au fil
  // audio de preparer l'emplacement. C'est ce qui ferme la course de
  // reutilisation — le fil principal n'a plus aucun acces a une structure que
  // le fil audio peut parcourir.
  voice_h voice_alloc(int port);
  void    voice_release(voice_h h);
  bool    voice_valid(voice_h h) const;

  // Port d'une voix, -1 si le handle est invalide. Une commande doit partir sur
  // l'anneau de SON port : c'est ce qui garantit qu'elle est appliquee dans le
  // meme bloc que le rendu qu'elle concerne.
  int     voice_port(voice_h h) const;

  // Frame absolu du premier echantillon reellement audible, -1 si la voix n'a
  // pas encore demarre. Note par la voix elle-meme : c'est une mesure sans
  // course, contrairement a une lecture externe de (horloge, position).
  frame_t voice_started_at(voice_h h) const;

  // Depose une commande. Rend false si l'anneau du port est plein (le seul cas
  // realiste est un consommateur mort — voir heartbeat()).
  bool post(int port, const Cmd& c);

  // Etat d'une voix, pour l'affichage. Lit les valeurs PUBLIEES en fin de bloc :
  // elles peuvent avoir un bloc de retard, ce qui est sans importance pour un
  // dessin, et elles sont formellement definies, ce qu'une lecture directe de la
  // structure ne serait pas.
  bool voice_query(voice_h h, double* pos_frames, int* state) const;

  // Horloge : frame absolu courant, tel que le fil audio le compte.
  frame_t clock_now() const { return clock_.load(std::memory_order_acquire); }
  frame_t block_index() const { return blocks_.load(std::memory_order_acquire); }

  // Taille du dernier bloc peripherique observee. C'est le chiffre qui dit a
  // quel tampon la machine tourne reellement — 64 ou 1024 ne se devinent pas.
  int last_block_frames() const { return last_tick_.load(std::memory_order_relaxed); }

  // Battement : le fil principal l'appelle a chaque frame. Si le fil audio ne
  // consomme plus (peripherique ferme, projet en chargement), la difference
  // cesse de bouger et l'appelant peut cesser de remplir l'anneau.
  frame_t heartbeat() const { return clock_now(); }

  void panic();

  // Le moteur de lanes MIDI. Il vit ICI plutot qu'a cote parce qu'il a besoin
  // d'exactement deux choses que l'Engine possede deja : le battement par bloc
  // (tick) et l'horloge en echantillons. Lui donner sa propre pulsation aurait
  // fait deux horloges dans un moteur dont tout le dossier dit qu'il n'en a
  // qu'une.
  Lanes& lanes() { return lanes_; }
  const Lanes& lanes() const { return lanes_; }

  // Rend au port toutes ses voix, immediatement et sans passer par l'anneau.
  //
  // A n'appeler QUE lorsque le port ne rend plus — c'est-a-dire apres que
  // StopTrackPreview2 a rendu la main. C'est la SEULE exception a la regle de
  // propriete, et elle est sure precisement parce qu'il n'y a plus de second
  // fil : personne ne parcourt ces voix a cet instant. Sans elle, une voix en
  // cours d'extinction reste eternellement en kVoiceStopping — son port ayant
  // cesse de rendre, plus personne ne fera avancer son fondu, et son
  // emplacement est perdu (defaut trouve a la sonde du 2026-07-31).
  void port_reset(int port);

  // --- fil audio ------------------------------------------------------------

  // Avance l'horloge d'un bloc peripherique.
  //
  // A APPELER APRES le rendu du bloc, jamais avant — c'est le passage « post »
  // du hook materiel (OnAudioBuffer avec isPost = true). clock_ est le nombre
  // d'echantillons DEJA delivres, donc l'index absolu du prochain echantillon a
  // produire. L'appeler avant etiquetterait chaque bloc avec l'heure de sa fin,
  // et tout partirait un bloc trop tot — bug trouve par le harnais, invisible a
  // l'oreille (1,3 ms), et qu'on aurait cherche dans REAPER.
  void tick(int frames);

  // Remplit out (entrelace, nch canaux) pour un port. Ecrase le tampon.
  // Rend le frame absolu du PREMIER echantillon du tampon, ou -1 si refuse.
  // L'appelant en a besoin pour dater autre chose que de l'audio — un evenement
  // MIDI, par exemple, dont l'offset se compte depuis ce frame.
  frame_t render_port(int port, sample_t* out, int frames, int nch);

  // --- diagnostic -----------------------------------------------------------
  int active_voices() const;
  int owned_voices() const;
  int port_voices(int port) const;

  // Taille de la liste que le fil audio parcourt pour ce port. A LIRE SEULEMENT
  // quand le fil audio est arrete : c'est une autopsie, pas un indicateur. Elle
  // sert au harnais a verifier qu'aucune entree ne survit a la liberation de son
  // emplacement — une entree orpheline ferait rendre une voix deux fois.
  int port_list_size(int port) const {
    return (port >= 0 && port < kMaxPorts) ? ports_[port].vcount : -1;
  }
  uint32_t dropped_commands() const { return dropped_.load(std::memory_order_relaxed); }

 private:
  void drain(int port, frame_t block_start);
  void apply(int port, const Cmd& c, frame_t block_start);
  void port_attach_voice(int port, int index);

  Pool       pool_;
  Lanes      lanes_;
  Voice      voices_[kMaxVoices];
  PortState  ports_[kMaxPorts];

  // Propriete des emplacements. Ecrit par le fil principal ; le fil audio n'y
  // efface que le bit `owned`.
  std::atomic<claim_t> claim_[kMaxVoices];
  int        alloc_cursor_;      // fil principal : reprend ou il s'est arrete

  double     srate_;
  std::atomic<frame_t>  clock_;
  std::atomic<frame_t>  blocks_;
  std::atomic<uint32_t> dropped_;
  std::atomic<int>      last_tick_;
  bool       clock_external_;    // vrai des que tick() a ete appele une fois
  int        clock_master_;      // port qui fait office d'horloge sans hook
  int        last_master_frames_;
};

} // namespace cp
