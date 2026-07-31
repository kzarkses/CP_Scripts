// Une voix : un clip, une position, un rendez-vous.
//
// La voix est la SEULE chose que le moteur connait. Pas de scene, pas de
// colonne, pas de cellule — c'est le principe de propriete du dossier §2.1.
// Une politique de session se decrit entierement avec « joue au frame N »,
// « arrete au frame M » et « enchaine sur la voix H ».
//
// PROPRIETE : cette structure appartient au FIL AUDIO, integralement. Le fil
// principal ne l'ecrit jamais — il pose un mot de propriete (claim_t, cp_types.h)
// et poste une commande. Les trois seules valeurs qu'il LIT sont publiees en fin
// de bloc dans les atomiques `pub_*` : une lecture de dessin, qui peut avoir un
// bloc de retard et pour qui c'est sans importance.
#pragma once

#include <atomic>
#include "cp_types.h"

namespace cp {

class Pool;

struct Voice {
  // --- identite -------------------------------------------------------------
  int      state;        // VoiceState
  uint16_t gen;          // generation courante, telle que le fil audio la connait
  int      port;         // -1 si non assignee

  // --- matiere --------------------------------------------------------------
  int      clip;         // slot du vivier, -1 si aucun
  double   pos;          // position de lecture en frames source (fractionnaire)

  // --- rendez-vous ----------------------------------------------------------
  frame_t  start_at;     // frame absolu du premier echantillon audible
  frame_t  stop_at;      // frame absolu de la coupure, ou INT64_MAX
  int      mode;         // PlayMode

  // --- transformation -------------------------------------------------------
  double   rate;         // 1.0 = vitesse d'origine
  float    gain;         // lineaire, applique avec rampe
  float    gain_target;
  float    pan;          // -1..+1
  frame_t  loop_start;   // en frames source
  frame_t  loop_end;     // 0 = fin du clip

  // --- fondus ---------------------------------------------------------------
  int      fade_in_len;    // en frames
  int      fade_in_pos;
  int      fade_out_len;
  int      fade_out_pos;

  // --- enchainement ---------------------------------------------------------
  // Correction §11.12 : legato, fondu croise et fin exacte ont une fenetre d'UN
  // bloc. Lua ne peut structurellement pas la tenir (16 a 74 ms par frame). Le
  // moteur possede donc UN emplacement « suivant » par voix. Un champ, pas un
  // modele de session.
  int      next_voice;   // index, -1 si aucun
  int      xfade_len;    // frames de fondu croise a l'enchainement
  // Frame ABSOLU du premier echantillon reellement audible, -1 tant que la voix
  // n'a pas demarre. C'est la verite terrain de l'attaque : la mesurer de
  // l'exterieur en lisant (horloge, position) expose a une course — dans un
  // bloc, `pos` avance au pull de l'apercu et l'horloge au passage post du hook,
  // donc une lecture qui tombe entre les deux voit un bloc d'ecart. Ici, aucune
  // course : c'est la voix elle-meme qui note l'instant.
  frame_t  started_at;

  frame_t  ended_at;     // frame ABSOLU ou la voix s'est eteinte, -1 sinon.
                         // C'est ce qui rend l'enchainement exact a
                         // l'echantillon plutot qu'exact au bloc.

  // Le fil principal a rendu cet emplacement ; le fil audio doit l'eteindre puis
  // effacer le bit de propriete. Tant que ce drapeau est pose, l'emplacement ne
  // peut PAS etre realloue — c'est ce qui rend la reutilisation sure.
  bool     free_pending;

  // --- publication vers le fil principal ------------------------------------
  // Ecrites une fois par bloc, jamais dans la boucle chaude. En relaxed : il n'y
  // a rien a ordonner autour d'elles, seulement a rendre la lecture definie.
  std::atomic<double>  pub_pos;
  std::atomic<int>     pub_state;
  std::atomic<int64_t> pub_started;

  void reset();
  bool active() const { return state != kVoiceIdle; }

  // Publie l'etat visible depuis Lua. Appelee une fois par bloc et par voix, a
  // la fin du rendu du port.
  void publish() {
    pub_pos.store(pos, std::memory_order_relaxed);
    pub_state.store(state, std::memory_order_relaxed);
    pub_started.store((int64_t)started_at, std::memory_order_relaxed);
  }

  // Rend et ADDITIONNE dans out (entrelace, nch canaux, frames images).
  // block_start est le frame absolu du premier echantillon du tampon.
  // Aucune allocation, aucun verrou, aucun appel systeme.
  void render(const Pool& pool, sample_t* out, int frames, int nch,
              frame_t block_start, double engine_srate);
};

} // namespace cp
