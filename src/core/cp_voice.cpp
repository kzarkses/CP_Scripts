#include "cp_voice.h"
#include "cp_pool.h"

#include <cmath>
#include <cstring>
#include <limits>

namespace cp {

// Seuil sous lequel un gain est force a zero. Les denormaux coutent 100 a 400
// cycles sur un Athlon 64 ou un P4 — c'est le seul piege capable a lui seul de
// rendre le moteur inutilisable sur la cible. On les tue a la source plutot que
// de poser FTZ/DAZ globalement : REAPER regle deja le MXCSR de son fil audio, et
// le modifier depuis un module charge degraderait tous les autres plugins.
static const float kDenormalFloor = 1e-15f;

void Voice::reset() {
  state = kVoiceIdle;
  port = -1;
  clip = -1;
  pos = 0.0;
  start_at = 0;
  stop_at = (std::numeric_limits<frame_t>::max)();
  mode = kPlayOnce;
  rate = 1.0;
  gain = 1.0f;
  gain_target = 1.0f;
  pan = 0.0f;
  loop_start = 0;
  loop_end = 0;
  fade_in_len = 0;
  fade_in_pos = 0;
  fade_out_len = 0;
  fade_out_pos = 0;
  next_voice = -1;
  xfade_len = 0;
  ended_at = -1;
}

// Hermite 4 points. Choisi contre le lineaire (audible sur des transitoires) et
// contre un sinc 64 taps (hors budget sur la machine cible). ~10 operations par
// echantillon et par canal, sans table, sans branchement.
static inline float hermite(float xm1, float x0, float x1, float x2, float t) {
  const float c = (x1 - xm1) * 0.5f;
  const float v = x0 - x1;
  const float w = c + v;
  const float a = w + v + (x2 - x0) * 0.5f;
  const float b = w + a;
  return ((((a * t) - b) * t + c) * t + x0);
}

void Voice::render(const Pool& pool, sample_t* out, int frames, int nch,
                   frame_t block_start, double engine_srate) {
  (void)engine_srate;
  if (state == kVoiceIdle) return;

  const Clip* c = pool.get(clip);
  if (!c || !c->data || c->frames <= 0) return;

  // Ou commence-t-on dans ce bloc ? C'est ici, et nulle part ailleurs, que se
  // joue l'exactitude a l'echantillon : le rendez-vous n'est pas arrondi au
  // bloc, il est converti en decalage a l'interieur du bloc.
  int off = 0;
  if (state == kVoiceScheduled) {
    if (start_at >= block_start + frames) return;       // pas encore
    off = (int)(start_at > block_start ? (start_at - block_start) : 0);
    state = kVoicePlaying;
    if (fade_in_len > 0) fade_in_pos = 0;
  }

  // Coupure datee, elle aussi a l'interieur du bloc.
  int n = frames;
  if (stop_at < block_start + frames) {
    const frame_t rel = stop_at - block_start;
    n = (int)(rel < 0 ? 0 : rel);
    if (n < off) n = off;
  }
  if (n <= off) {
    if (stop_at <= block_start) {
      state = kVoiceIdle;
      clip = -1;
      ended_at = stop_at;
    }
    return;
  }

  const frame_t src_end   = (loop_end > 0 && loop_end <= c->frames) ? loop_end : c->frames;
  const frame_t src_start = (loop_start >= 0 && loop_start < src_end) ? loop_start : 0;
  const frame_t span      = src_end - src_start;
  const int     cnch      = c->nch;
  const sample_t* data    = c->data;

  // Balance, pas panoramique a puissance constante. Un lanceur de clips joue du
  // materiau deja mixe : au centre, il doit passer a l'identique. Une loi a
  // puissance constante mettrait -3 dB sur tout ce qui n'est pas panoramique, ce
  // qui est faux ici et rend le rendu non comparable a la source.
  const float pnorm = (pan < -1.0f ? -1.0f : (pan > 1.0f ? 1.0f : pan));
  const float gl    = (pnorm > 0.0f) ? (1.0f - pnorm) : 1.0f;
  const float gr    = (pnorm < 0.0f) ? (1.0f + pnorm) : 1.0f;

  // Rampe de gain sur le bloc : un saut de gain sec s'entend, et une rampe par
  // bloc coute une addition par echantillon.
  float g = gain;
  const float gstep = (n > off) ? (gain_target - gain) / (float)(n - off) : 0.0f;

  const bool unity = (rate > 0.99999999 && rate < 1.00000001);

  for (int i = off; i < n; ++i) {
    // --- fin de matiere ------------------------------------------------------
    if (pos >= (double)src_end) {
      if (mode == kPlayLoop && span > 0) {
        // Repli exact : on retire un nombre entier de spans, la phase
        // fractionnaire est preservee. C'est ce qui evite la derive d'un
        // echantillon par tour, invisible au debut et fatale au bout de dix
        // minutes.
        while (pos >= (double)src_end) pos -= (double)span;
      } else {
        state = kVoiceIdle;
        clip = -1;
        ended_at = block_start + i;
        break;
      }
    }

    // --- lecture interpolee --------------------------------------------------
    const frame_t i0 = (frame_t)pos;
    float l, r;

    if (unity) {
      const sample_t* p = data + (size_t)i0 * cnch;
      l = p[0];
      r = (cnch > 1) ? p[1] : p[0];
    } else {
      const float t = (float)(pos - (double)i0);
      frame_t im1 = i0 - 1, i1 = i0 + 1, i2 = i0 + 2;
      // Bornage par repli dans la zone de boucle : jamais de lecture hors du
      // tampon, et pas de branchement imprevisible dans la boucle chaude.
      if (im1 < src_start) im1 = (mode == kPlayLoop && span > 0) ? src_end - 1 : src_start;
      if (i1 >= src_end)   i1  = (mode == kPlayLoop && span > 0) ? src_start : src_end - 1;
      if (i2 >= src_end)   i2  = (mode == kPlayLoop && span > 0) ? src_start : src_end - 1;

      const sample_t* pm1 = data + (size_t)im1 * cnch;
      const sample_t* p0  = data + (size_t)i0  * cnch;
      const sample_t* p1  = data + (size_t)i1  * cnch;
      const sample_t* p2  = data + (size_t)i2  * cnch;

      l = hermite(pm1[0], p0[0], p1[0], p2[0], t);
      r = (cnch > 1) ? hermite(pm1[1], p0[1], p1[1], p2[1], t) : l;
    }

    // --- enveloppes ----------------------------------------------------------
    float env = 1.0f;
    if (fade_in_len > 0 && fade_in_pos < fade_in_len) {
      env *= (float)fade_in_pos / (float)fade_in_len;
      ++fade_in_pos;
    }
    if (state == kVoiceStopping) {
      if (fade_out_len > 0 && fade_out_pos < fade_out_len) {
        env *= 1.0f - (float)fade_out_pos / (float)fade_out_len;
        ++fade_out_pos;
      } else {
        state = kVoiceIdle;
        clip = -1;
        ended_at = block_start + i;
        break;
      }
    }

    g += gstep;
    float gg = g * env;
    if (gg < kDenormalFloor && gg > -kDenormalFloor) gg = 0.0f;

    sample_t* o = out + (size_t)i * nch;
    o[0] += l * gg * gl;
    if (nch > 1) o[1] += r * gg * gr;

    pos += rate;
  }

  gain = gain_target;

  // Coupure nette datee : la voix s'eteint exactement au frame demande.
  if (stop_at < block_start + frames && state != kVoiceIdle && fade_out_len == 0) {
    state = kVoiceIdle;
    clip = -1;
    ended_at = stop_at;
  }
}

} // namespace cp
