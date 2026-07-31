#include "cp_source.h"

#include <cstdlib>
#include <cstring>
#include <cmath>

namespace cp {

// Taille maximale d'un bloc demande par l'hote. REAPER ne depasse jamais cela
// en pratique ; si un jour il le fait, GetSamples decoupe au lieu d'allouer.
static const int kScratchFrames = 8192;

PortSource::PortSource(Engine* eng, int port)
    : eng_(eng), port_(port), scratch_(nullptr), scratch_frames_(0),
      calls_(0), last_time_s_(-1.0), max_gap_s_(0.0), last_len_(0) {
  const size_t n = (size_t)kScratchFrames * kMaxChans;
#if defined(_MSC_VER)
  scratch_ = (sample_t*)_aligned_malloc(n * sizeof(sample_t), 64);
#else
  posix_memalign((void**)&scratch_, 64, n * sizeof(sample_t));
#endif
  if (scratch_) {
    std::memset(scratch_, 0, n * sizeof(sample_t));
    scratch_frames_ = kScratchFrames;
  }
}

PortSource::~PortSource() {
#if defined(_MSC_VER)
  if (scratch_) _aligned_free(scratch_);
#else
  if (scratch_) free(scratch_);
#endif
  scratch_ = nullptr;
}

void PortSource::GetSamples(PCM_source_transfer_t* block) {
  if (!block || !block->samples || block->length <= 0) return;

  const int nch = (block->nch > 0) ? block->nch : 2;
  const int want = block->length;

  // --- instrumentation, sans jamais bloquer ---------------------------------
  // Detecte une demande NON contigue : c'est la seule chose qui pourrait rendre
  // « compter ses echantillons » faux, et c'est la question ouverte §12.5.1.
  if (last_time_s_ >= 0.0) {
    const double expected = last_time_s_ + (double)last_len_ / GetSampleRate();
    const double gap = std::fabs(block->time_s - expected);
    if (gap > max_gap_s_) max_gap_s_ = gap;
  }
  last_time_s_ = block->time_s;
  last_len_ = want;
  ++calls_;

  if (!eng_ || !scratch_) {
    std::memset(block->samples, 0, (size_t)want * nch * sizeof(ReaSample));
    block->samples_out = want;
    return;
  }

  // On ne rend jamais plus que le tampon prealloue : on decoupe. Une allocation
  // ici serait un verrou deguise dans le fil audio.
  int done = 0;
  const int chans = (nch < kMaxChans) ? nch : kMaxChans;
  while (done < want) {
    const int n = ((want - done) > scratch_frames_) ? scratch_frames_ : (want - done);
    eng_->render_port(port_, scratch_, n, chans);

    ReaSample* out = block->samples + (size_t)done * nch;
    for (int i = 0; i < n; ++i) {
      const sample_t* s = scratch_ + (size_t)i * chans;
      ReaSample* o = out + (size_t)i * nch;
      for (int ch = 0; ch < nch; ++ch) o[ch] = (ReaSample)((ch < chans) ? s[ch] : 0.0f);
    }
    done += n;
  }

  block->samples_out = want;

  // On ne declare aucune latence : le moteur ne met rien en tampon entre la
  // demande et la sortie. Le jour ou un etireur entre dans la chaine, c'est ICI
  // qu'il faudra la declarer, et elle sera connue par amorcage (§11.9).
  block->approximate_playback_latency = 0.0;
}

void PortSource::GetPeakInfo(PCM_source_peaktransfer_t* block) {
  // Un port n'a pas de forme d'onde a montrer : il n'est pas un fichier, il est
  // une sortie. Les apercus de clips se dessinent en Lua a partir du vivier.
  if (block) block->peaks_out = 0;
}

} // namespace cp
