// Le vivier d'echantillons : les clips resident en RAM, decodes une seule fois.
//
// Le cœur NE LIT PAS de fichier — il ne connait pas REAPER. L'hote decode
// (PCM_source de REAPER, donc tous les formats que REAPER lit) sur un fil de
// travail, puis publie ici. Le fil audio ne voit un clip que lorsque son etat
// passe a kClipReady par un store(release).
//
// Aucune liberation depuis le fil audio. Un clip qu'on veut jeter est marque, et
// le fil principal ne libere qu'apres avoir vu passer deux blocs audio — la
// barriere de dechargement du dossier §12.2/B9.
#pragma once

#include <atomic>
#include "cp_types.h"

namespace cp {

struct Clip {
  std::atomic<int>     state;      // ClipState
  std::atomic<int>     refs;       // voix qui le referencent (fil principal)
  sample_t*            data;       // entrelace, nch * frames. Possede par le pool.
  frame_t              frames;
  int                  nch;
  double               srate;      // taux du materiau tel que stocke
  frame_t              retire_at;  // bloc audio a partir duquel la liberation est sure
  bool                 retire_wanted;  // on a demande le retrait, une voix le tenait
  uint32_t             gen;        // detecte un slot recycle

  // L'ordre suit celui des membres : une liste d'initialisation qui s'en ecarte
  // n'initialise pas dans l'ordre qu'elle affiche, et se lit donc a l'envers de
  // ce qu'elle fait.
  Clip() : state(kClipEmpty), refs(0), data(nullptr), frames(0), nch(0),
           srate(0.0), retire_at(0), retire_wanted(false), gen(0) {}
};

class Pool {
 public:
  Pool();
  ~Pool();

  // --- fil principal / fil de travail ---------------------------------------

  // Reserve un slot. Rend -1 si le vivier est plein.
  int  acquire();

  // --- le comptage de references, tenu par le FIL PRINCIPAL ------------------
  // Il se DEDUIT de ce que les voix publient : compter dans le fil audio aurait
  // demande a chaque voix d'incrementer au demarrage et de decrementer a la
  // mort, donc quatre chemins a ne jamais rater. Un balayage des voix, appele
  // au moment ou on veut liberer, repond a la meme question sans etat.
  void clear_refs();
  void add_ref(int slot);

  // Alloue le tampon d'un slot reserve. Une seule allocation par clip, hors du
  // fil audio. Rend false si la taille depasse le plafond decide (§12.1).
  bool alloc(int slot, frame_t frames, int nch, double srate);

  // Acces en ecriture au tampon, tant que l'etat est kClipLoading.
  sample_t* writable(int slot);

  // Publie le clip : c'est le seul point ou le fil audio commence a le voir.
  void publish(int slot);
  void fail(int slot);

  // Marque un slot pour liberation. La memoire n'est rendue que par collect().
  // ⚠️ RETIRER, C'EST DEMANDER — PAS FAIRE. Un clip qu'une voix joue encore
  // reste VISIBLE et RESIDENT : le rendre invisible faisait obtenir `nullptr` a
  // la voix au bloc suivant, et elle mourait sans fondu au milieu d'un son.
  // C'est ce qui arrivait a chaque changement de mode tempo sous une case en
  // train de jouer. La demande est notee et honoree par `collect`, des que plus
  // personne ne tient la matiere.
  void retire(int slot, frame_t audio_block_now);

  // A appeler regulierement depuis le fil principal. Libere ce qui a franchi la
  // barriere de deux blocs.
  void collect(frame_t audio_block_now);

  // --- fil audio (lecture seule) --------------------------------------------

  // Rend nullptr si le slot n'est pas pret. Aucune allocation, aucun verrou.
  const Clip* get(int slot) const {
    if (slot < 0 || slot >= kMaxClips) return nullptr;
    const Clip& c = clips_[slot];
    if (c.state.load(std::memory_order_acquire) != kClipReady) return nullptr;
    return &c;
  }

  int capacity() const { return kMaxClips; }
  int loaded_count() const;
  size_t bytes_resident() const;

 private:
  Clip clips_[kMaxClips];
  size_t bytes_;
};

} // namespace cp
