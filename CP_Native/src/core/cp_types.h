// CP_Native — cœur du moteur de clips.
//
// REGLE ABSOLUE DE CE DOSSIER (src/core) : aucun appel a l'API REAPER, aucune
// inclusion du SDK, aucune I/O, aucune allocation apres l'initialisation.
// C'est ce qui rend le harnais hors-ligne possible (src/test) : le cœur se
// compile et se verifie sans REAPER. Si cette regle tombe, on debogue a
// l'aveugle dans le fil audio, et on s'en apercoit trois mois trop tard.
#pragma once

#include <cstdint>
#include <cstddef>

namespace cp {

// Format interne. float32 : moitie moins de memoire et de bande passante que
// double, et la conversion vers ReaSample se fait une seule fois, a la
// frontiere (host/cp_source.cpp).
typedef float sample_t;

// Temps. Le moteur ne connait QUE l'echantillon absolu, jamais le beat, jamais
// la seconde. La carte de tempo reste en Lua, sur le fil principal, ou elle est
// exacte (TimeMap2_*). C'est la correction B3 du dossier §12.2.
typedef int64_t frame_t;

// « des que possible » pour un rendez-vous non date.
static const frame_t kNow = INT64_MIN;

enum : int {
  kMaxPorts   = 32,   // une colonne = un port
  kMaxVoices  = 256,  // 8 voix par port a pleine charge
  kMaxClips   = 512,  // echantillons resident en RAM
  kMaxChans   = 2,    // v1 : mono ou stereo
  // Plafond par port. Il n'est pas cosmetique : c'est lui qui borne la liste que
  // le fil audio parcourt a chaque bloc. Avant lui, render_port balayait les 256
  // voix pour en trouver huit — 38 Ko de structures traversees par port et par
  // bloc, soit plus que le L1 d'une machine ancienne. Maintenant il ne touche
  // que ses propres voix.
  kMaxPortVoices = 64,
  // 256 commandes par port. Draine a chaque bloc, ca represente 192 000
  // commandes par seconde a 64 echantillons — trois ordres de grandeur au-dessus
  // de ce qu'une interface humaine peut produire. Le seul cas de saturation
  // realiste n'est pas la rafale, c'est le CONSOMMATEUR MORT (peripherique
  // ferme, projet en chargement) : il se detecte au battement, pas a la taille.
  // 1024 aurait coute 1,3 Mo de RAM pour rien.
  kCmdRingCap = 256,  // par port ; puissance de deux obligatoire
};

// Bornes memoire. Decidees avec l'auteur le 2026-07-31 : des boucles de
// 16 mesures, pas des stems. 16 mesures a 4/4 et 60 BPM = 64 s, ce qui est le
// pire cas realiste. 64 s * 48 kHz * 2 canaux * 4 octets = 24,6 Mo par clip.
// Le plafond total tient la RAM d'une machine ancienne.
static const frame_t kMaxClipFrames = 64 * 96000; // 64 s a 96 kHz

enum ClipState : int {
  kClipEmpty = 0,
  kClipLoading,   // le fil de travail ecrit ; le fil audio ne doit pas lire
  kClipReady,     // publie par un store(release) ; lisible par le fil audio
  kClipError,
};

enum VoiceState : int {
  kVoiceIdle = 0,
  kVoiceScheduled, // a un rendez-vous dans le futur
  kVoicePlaying,
  kVoiceStopping,  // en fondu de sortie
};

enum PlayMode : int {
  kPlayOnce = 0,
  kPlayLoop,
};

// Handle opaque rendu a Lua. L'index seul ne suffit pas : dans ce depot les
// scripts meurent et redemarrent en permanence, et un handle perime doit etre
// detecte, pas reutilise en silence. 16 bits d'index, 16 bits de generation.
typedef uint32_t voice_h;
static const voice_h kNullVoice = 0xFFFFFFFFu;

inline voice_h make_handle(int index, uint16_t gen) {
  return (voice_h)((uint32_t)(gen) << 16 | (uint32_t)(index & 0xFFFF));
}
inline int handle_index(voice_h h) { return (int)(h & 0xFFFF); }
inline uint16_t handle_gen(voice_h h) { return (uint16_t)(h >> 16); }

// ---------------------------------------------------------------------------
// Le mot de propriete d'une voix — un seul entier atomique par emplacement.
//
// C'est la piece qui ferme la course de reutilisation. Avant, le fil principal
// ecrivait DANS la voix pour l'allouer, pendant que le fil audio pouvait encore
// la parcourir. Benin sur x86 par accident (TSO), piege garanti sur ARM.
//
// Maintenant la propriete et l'etat sont deux choses distinctes :
//   * le mot ci-dessous appartient au FIL PRINCIPAL, sauf le bit `owned` que le
//     fil audio est seul a EFFACER, et seulement quand il en a fini ;
//   * la structure Voice appartient au FIL AUDIO, integralement.
// Le fil principal demande, le fil audio execute — comme toute autre commande.
//
//   bits 0..15  generation      (jamais 0 : 0 = emplacement vierge)
//   bit  16     possede         (pose par le principal, efface par l'audio)
//   bits 17..22 port            (0..31)
// ---------------------------------------------------------------------------
typedef uint32_t claim_t;
static const claim_t kClaimOwned    = 1u << 16;
static const claim_t kClaimGenMask  = 0xFFFFu;
static const int     kClaimPortShift = 17;
static const claim_t kClaimPortMask = 0x3Fu << kClaimPortShift;

inline claim_t make_claim(uint16_t gen, int port) {
  return (claim_t)gen | kClaimOwned | ((claim_t)(port & 0x3F) << kClaimPortShift);
}
inline uint16_t claim_gen(claim_t c)  { return (uint16_t)(c & kClaimGenMask); }
inline bool     claim_owned(claim_t c){ return (c & kClaimOwned) != 0; }
inline int      claim_port(claim_t c) { return (int)((c & kClaimPortMask) >> kClaimPortShift); }

// ---------------------------------------------------------------------------
// Commandes fil principal -> fil audio. POD strict, taille fixe, aucune
// indirection : le fil audio ne doit jamais suivre un pointeur qu'il n'a pas
// lui-meme publie.
// ---------------------------------------------------------------------------
enum CmdType : uint32_t {
  kCmdNone = 0,
  kCmdVoicePlay,     // a = rate, b = gain, u0 = clip, u1 = mode
  kCmdVoiceStop,     // a = fade_out en secondes
  kCmdVoiceSet,      // u0 = ParamId, a = valeur
  kCmdVoiceQueue,    // u0 = handle suivant, a = crossfade en secondes
  kCmdPortGain,      // a = gain
  kCmdPanic,         // tout couper, sans clic
  // Prise et remise d'un emplacement. Le fil principal ne touche JAMAIS la
  // structure Voice : il pose son mot de propriete, puis demande ici.
  kCmdVoiceAlloc,    // voice = handle NEUF, u1 = port
  kCmdVoiceFree,     // voice = handle A RENDRE, u0 = generation a installer
};

enum ParamId : uint32_t {
  kParamRate = 0,
  kParamGain,
  kParamPan,
  kParamLoopStart,   // en frames source
  kParamLoopEnd,
  kParamFadeIn,      // en secondes
  kParamFadeOut,
  kParamPos,         // deplacement de la tete de lecture, en frames source
  kParamLoop,        // 0 = une fois, non nul = boucle. Change A LA VOLEE.
};

struct Cmd {
  uint32_t type;
  uint32_t voice;   // handle
  frame_t  at;      // echantillon absolu, ou kNow
  double   a;
  double   b;
  uint32_t u0;
  uint32_t u1;
};
static_assert(sizeof(Cmd) == 40, "Cmd doit rester POD et compact");

} // namespace cp
