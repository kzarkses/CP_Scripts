// Le moteur : N ports (une colonne = un port), M voix, un vivier, une horloge.
//
// L'horloge est le point delicat de toute l'architecture, et le voici resolu
// explicitement (dossier §12.6, consequence 3) : le fil audio ne DEMANDE jamais
// l'heure, il COMPTE ses echantillons. Une ancre unique, prise sur le fil
// principal, suffit a convertir un instant du projet en frame absolu — et il n'y
// a aucune derive a rattraper, puisque la boucle et le projet sont entraines par
// la meme horloge de carte son (mesure du 2026-07-30).
#pragma once

#include <atomic>
#include "cp_types.h"
#include "cp_ring.h"
#include "cp_pool.h"
#include "cp_voice.h"

namespace cp {

struct PortState {
  SpscRing<Cmd, kCmdRingCap> cmds;
  float   gain;
  float   gain_target;
  frame_t last_clock;   // valeur de l'horloge au dernier bloc observe
  int     consumed;     // frames deja rendus dans le bloc courant
  bool    used;

  PortState() : gain(1.0f), gain_target(1.0f), last_clock(-1), consumed(0), used(false) {}
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

  // Etat d'une voix, pour l'affichage. Lecture non verrouillee : la valeur peut
  // avoir un bloc de retard, ce qui est sans importance pour un dessin.
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

  // Rend au port toutes ses voix, immediatement et sans passer par l'anneau.
  //
  // A n'appeler QUE lorsque le port ne rend plus — c'est-a-dire apres que
  // StopTrackPreview2 a rendu la main. Sans cela, une voix en cours
  // d'extinction reste eternellement en kVoiceStopping : son port ayant cesse
  // de rendre, plus personne ne fera jamais avancer son fondu, et son slot est
  // perdu. Defaut trouve sur la sonde du 2026-07-31 (voices=2 pour une seule
  // voix allouee).
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
  void render_port(int port, sample_t* out, int frames, int nch);

  // --- diagnostic -----------------------------------------------------------
  int active_voices() const;
  uint32_t dropped_commands() const { return dropped_.load(std::memory_order_relaxed); }

 private:
  void drain(int port, frame_t block_start);
  void apply(const Cmd& c, frame_t block_start);

  Pool       pool_;
  Voice      voices_[kMaxVoices];
  bool       owned_[kMaxVoices];
  PortState  ports_[kMaxPorts];

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
