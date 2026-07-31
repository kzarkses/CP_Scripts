// Anneau SPSC sans verrou : un producteur (fil principal, via Lua), un
// consommateur (fil audio). Capacite fixe, allouee au chargement.
//
// Pourquoi acquire/release explicites et pas seq_cst : sur x86 c'est gratuit,
// mais sur ARM (macOS Apple Silicon, l'etape « reste du monde ») un
// memory_order relache casse de facon intermittente et non reproductible sur la
// machine de dev. On ecrit les barrieres maintenant, pas quand le bug arrive.
#pragma once

#include <atomic>
#include "cp_types.h"

namespace cp {

template <typename T, unsigned N>
class SpscRing {
  static_assert((N & (N - 1)) == 0, "capacite doit etre une puissance de deux");

 public:
  SpscRing() : w_(0), r_(0) {}

  // Fil producteur uniquement.
  bool push(const T& v) {
    const uint32_t w = w_.load(std::memory_order_relaxed);
    const uint32_t r = r_.load(std::memory_order_acquire);
    if ((uint32_t)(w - r) >= N) return false;   // plein
    buf_[w & (N - 1)] = v;
    w_.store(w + 1, std::memory_order_release); // publie la charge utile
    return true;
  }

  // Fil consommateur uniquement.
  bool pop(T& out) {
    const uint32_t r = r_.load(std::memory_order_relaxed);
    const uint32_t w = w_.load(std::memory_order_acquire);
    if (r == w) return false;                   // vide
    out = buf_[r & (N - 1)];
    r_.store(r + 1, std::memory_order_release);
    return true;
  }

  // Indicatif : sert au diagnostic, jamais a une decision.
  uint32_t size() const {
    return w_.load(std::memory_order_relaxed) - r_.load(std::memory_order_relaxed);
  }

  void clear() {
    r_.store(w_.load(std::memory_order_acquire), std::memory_order_release);
  }

 private:
  // Curseurs sur deux lignes de cache distinctes. Sans ca, le producteur et le
  // consommateur se battent pour la meme ligne a chaque operation (false
  // sharing) : mesurable, et d'autant plus couteux sur les vieux CPU.
  alignas(64) std::atomic<uint32_t> w_;
  alignas(64) std::atomic<uint32_t> r_;
  alignas(64) T buf_[N];
};

} // namespace cp
