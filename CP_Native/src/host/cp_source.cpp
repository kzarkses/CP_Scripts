#include "cp_source.h"

#include <cstdlib>
#include <cstring>
#include <cmath>

namespace cp {

// ---------------------------------------------------------------------------
// Chronometre du fil audio.
//
// QueryPerformanceCounter est une lecture de compteur, pas un appel systeme :
// une vingtaine de nanosecondes. C'est acceptable dans le fil audio, et c'est
// le prix a payer pour savoir ce que le moteur coute vraiment au lieu de
// l'estimer.
// ---------------------------------------------------------------------------
static std::atomic<long long> g_busy(0);

#ifdef _WIN32
static inline long long tick_now() {
  LARGE_INTEGER li;
  QueryPerformanceCounter(&li);
  return (long long)li.QuadPart;
}
long long PortSource_TickFreq() {
  LARGE_INTEGER li;
  QueryPerformanceFrequency(&li);
  return (long long)li.QuadPart;
}
#else
#include <time.h>
static inline long long tick_now() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}
long long PortSource_TickFreq() { return 1000000000LL; }
#endif

long long PortSource_BusyTicks() { return g_busy.load(std::memory_order_relaxed); }
void PortSource_ResetBusy() { g_busy.store(0, std::memory_order_relaxed); }

// Taille maximale d'un bloc demande par l'hote. REAPER ne depasse jamais cela
// en pratique ; si un jour il le fait, GetSamples decoupe au lieu d'allouer.
static const int kScratchFrames = 8192;

PortSource::PortSource(Engine* eng, int port)
    : eng_(eng), port_(port), scratch_(nullptr), scratch_frames_(0),
      calls_(0), last_time_s_(-1.0), max_gap_s_(0.0), last_len_(0),
      npending_(0), midi_out_(0), midi_list_seen_(false),
      midi_exact_(0), midi_late_(0), midi_max_err_(0) {
  std::memset(pending_, 0, sizeof(pending_));
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

  const long long t_in = tick_now();
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
    g_busy.fetch_add(tick_now() - t_in, std::memory_order_relaxed);
    return;
  }

  // On ne rend jamais plus que le tampon prealloue : on decoupe. Une allocation
  // ici serait un verrou deguise dans le fil audio.
  int done = 0;
  frame_t block_start = -1;
  const int chans = (nch < kMaxChans) ? nch : kMaxChans;
  while (done < want) {
    const int n = ((want - done) > scratch_frames_) ? scratch_frames_ : (want - done);
    const frame_t bs = eng_->render_port(port_, scratch_, n, chans);
    if (done == 0) block_start = bs;

    ReaSample* out = block->samples + (size_t)done * nch;
    for (int i = 0; i < n; ++i) {
      const sample_t* s = scratch_ + (size_t)i * chans;
      ReaSample* o = out + (size_t)i * nch;
      for (int ch = 0; ch < nch; ++ch) o[ch] = (ReaSample)((ch < chans) ? s[ch] : 0.0f);
    }
    done += n;
  }

  // --- MIDI experimental ----------------------------------------------------
  // On note d'abord si REAPER nous tend seulement une liste : s'il ne le fait
  // jamais pour un apercu de piste, la question est deja repondue, et par non.
  if (block->midi_events) midi_list_seen_ = true;

  if (block_start >= 0) {
    // LES LANES D'ABORD. Le moteur de lanes a date ses evenements pour CE
    // bloc pendant le tick precedent ; ils sont deja dans la file du port, et
    // les prendre ici est ce qui remplace la piste routeur, ses envois filtres
    // par canal et le plafond de seize.
    {
      const frame_t bend = block_start + want;
      frame_t       lat[64];
      unsigned char lmsg[64][3];
      const int n = eng_->lanes().drain_midi(port_, block_start, bend,
                                             lat, lmsg, 64);
      if (block->midi_events) {
        for (int i = 0; i < n; ++i) {
          MIDI_event_t ev;
          ev.frame_offset = (int)(lat[i] - block_start);
          if (ev.frame_offset < 0) ev.frame_offset = 0;
          if (ev.frame_offset >= want) ev.frame_offset = want - 1;
          ev.size = 3;
          ev.midi_message[0] = lmsg[i][0];
          ev.midi_message[1] = lmsg[i][1];
          ev.midi_message[2] = lmsg[i][2];
          ev.midi_message[3] = 0;
          block->midi_events->AddItem(&ev);
          ++midi_out_;
        }
      }
    }

    // Drainer la file d'entree vers le tableau local. Ce tableau n'appartient
    // qu'au fil audio, ce qui evite d'avoir besoin d'une file capable de
    // regarder son premier element sans le retirer.
    MidiEv e;
    while (npending_ < (int)(sizeof(pending_) / sizeof(pending_[0])) && midi_in_.pop(e))
      pending_[npending_++] = e;

    if (block->midi_events && npending_ > 0) {
      const frame_t bend = block_start + want;
      int keep = 0;
      for (int i = 0; i < npending_; ++i) {
        const MidiEv& p = pending_[i];
        if (p.at < bend) {
          MIDI_event_t ev;
          // Un evenement en retard part a l'offset 0 plutot que d'etre perdu :
          // mieux vaut une note d'un bloc en retard qu'une note muette.
          ev.frame_offset = (int)(p.at > block_start ? (p.at - block_start) : 0);
          // La verification, et non la promesse : l'instant reellement remis
          // vaut-il l'instant demande ?
          const frame_t reel = block_start + ev.frame_offset;
          if (reel == p.at) {
            ++midi_exact_;
          } else {
            ++midi_late_;
            const frame_t err = (reel > p.at) ? (reel - p.at) : (p.at - reel);
            if (err > midi_max_err_) midi_max_err_ = err;
          }
          ev.size = 3;
          ev.midi_message[0] = p.msg[0];
          ev.midi_message[1] = p.msg[1];
          ev.midi_message[2] = p.msg[2];
          ev.midi_message[3] = 0;
          block->midi_events->AddItem(&ev);
          ++midi_out_;
        } else {
          pending_[keep++] = p;   // pas encore l'heure
        }
      }
      npending_ = keep;
    }
  }

  block->samples_out = want;

  // On ne declare aucune latence : le moteur ne met rien en tampon entre la
  // demande et la sortie. Le jour ou un etireur entre dans la chaine, c'est ICI
  // qu'il faudra la declarer, et elle sera connue par amorcage (§11.9).
  block->approximate_playback_latency = 0.0;

  g_busy.fetch_add(tick_now() - t_in, std::memory_order_relaxed);
}

bool PortSource::queue_midi(frame_t at, unsigned char s,
                            unsigned char d1, unsigned char d2) {
  MidiEv e;
  e.at = at;
  e.msg[0] = s;
  e.msg[1] = d1;
  e.msg[2] = d2;
  return midi_in_.push(e);
}

void PortSource::GetPeakInfo(PCM_source_peaktransfer_t* block) {
  // Un port n'a pas de forme d'onde a montrer : il n'est pas un fichier, il est
  // une sortie. Les apercus de clips se dessinent en Lua a partir du vivier.
  if (block) block->peaks_out = 0;
}

} // namespace cp
