#include "cp_pool.h"

#include <cstdlib>
#include <cstring>
#include <new>

namespace cp {

// Alignement 64 : les tampons de clips sont lus en boucle serree par le
// resampleur ; les faire commencer sur une ligne de cache evite un
// chargement partiel par bloc.
static sample_t* aligned_alloc_samples(size_t n) {
#if defined(_MSC_VER)
  return (sample_t*)_aligned_malloc(n * sizeof(sample_t), 64);
#else
  void* p = nullptr;
  if (posix_memalign(&p, 64, n * sizeof(sample_t)) != 0) return nullptr;
  return (sample_t*)p;
#endif
}

static void aligned_free_samples(sample_t* p) {
  if (!p) return;
#if defined(_MSC_VER)
  _aligned_free(p);
#else
  free(p);
#endif
}

Pool::Pool() : bytes_(0) {}

Pool::~Pool() {
  for (int i = 0; i < kMaxClips; ++i) {
    aligned_free_samples(clips_[i].data);
    clips_[i].data = nullptr;
  }
  bytes_ = 0;
}

int Pool::acquire() {
  for (int i = 0; i < kMaxClips; ++i) {
    int expected = kClipEmpty;
    if (clips_[i].state.compare_exchange_strong(expected, kClipLoading,
                                                std::memory_order_acq_rel)) {
      clips_[i].frames = 0;
      clips_[i].nch = 0;
      clips_[i].srate = 0.0;
      clips_[i].retire_at = 0;
      clips_[i].refs.store(0, std::memory_order_relaxed);
      clips_[i].gen++;
      return i;
    }
  }
  return -1;
}

bool Pool::alloc(int slot, frame_t frames, int nch, double srate) {
  if (slot < 0 || slot >= kMaxClips) return false;
  if (frames <= 0 || frames > kMaxClipFrames) return false;
  if (nch < 1 || nch > kMaxChans) return false;

  Clip& c = clips_[slot];
  if (c.state.load(std::memory_order_relaxed) != kClipLoading) return false;

  aligned_free_samples(c.data);
  if (c.frames > 0) bytes_ -= (size_t)c.frames * c.nch * sizeof(sample_t);

  const size_t n = (size_t)frames * nch;
  c.data = aligned_alloc_samples(n);
  if (!c.data) {
    c.frames = 0;
    c.nch = 0;
    return false;
  }
  std::memset(c.data, 0, n * sizeof(sample_t));
  c.frames = frames;
  c.nch = nch;
  c.srate = srate;
  bytes_ += n * sizeof(sample_t);
  return true;
}

sample_t* Pool::writable(int slot) {
  if (slot < 0 || slot >= kMaxClips) return nullptr;
  Clip& c = clips_[slot];
  if (c.state.load(std::memory_order_relaxed) != kClipLoading) return nullptr;
  return c.data;
}

void Pool::publish(int slot) {
  if (slot < 0 || slot >= kMaxClips) return;
  // release : tout ce qui a ete ecrit dans data est visible pour le fil audio
  // avant que celui-ci ne voie kClipReady.
  clips_[slot].state.store(kClipReady, std::memory_order_release);
}

void Pool::fail(int slot) {
  if (slot < 0 || slot >= kMaxClips) return;
  clips_[slot].state.store(kClipError, std::memory_order_release);
}

void Pool::retire(int slot, frame_t audio_block_now) {
  if (slot < 0 || slot >= kMaxClips) return;
  Clip& c = clips_[slot];
  // Deux blocs : le fil audio peut etre EN TRAIN de rendre le bloc courant avec
  // ce clip, et un port peut encore l'avoir mis en cache localement.
  c.retire_at = audio_block_now + 2;
  c.state.store(kClipLoading, std::memory_order_release); // plus visible du fil audio
}

void Pool::collect(frame_t audio_block_now) {
  for (int i = 0; i < kMaxClips; ++i) {
    Clip& c = clips_[i];
    if (c.state.load(std::memory_order_acquire) != kClipLoading) continue;
    if (c.retire_at == 0) continue;                    // en cours de chargement
    if (audio_block_now < c.retire_at) continue;       // barriere non franchie
    if (c.refs.load(std::memory_order_acquire) > 0) continue;

    if (c.frames > 0) bytes_ -= (size_t)c.frames * c.nch * sizeof(sample_t);
    aligned_free_samples(c.data);
    c.data = nullptr;
    c.frames = 0;
    c.nch = 0;
    c.retire_at = 0;
    c.state.store(kClipEmpty, std::memory_order_release);
  }
}

int Pool::loaded_count() const {
  int n = 0;
  for (int i = 0; i < kMaxClips; ++i)
    if (clips_[i].state.load(std::memory_order_relaxed) == kClipReady) ++n;
  return n;
}

size_t Pool::bytes_resident() const { return bytes_; }

} // namespace cp
