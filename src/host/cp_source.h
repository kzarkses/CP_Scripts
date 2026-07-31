// Le port : une PCM_source maison, une par colonne, versee dans une piste par
// le service d'apercu de REAPER.
//
// Forme retenue (dossier §3.1) : un apercu PERMANENT, jamais arrete, jamais
// repositionne. Il rend du silence quand rien ne joue. Consequence directe : on
// ne cree ni ne detruit rien au lancement d'un clip — c'est la source du
// scintillement de fenetres et des pistes qui apparaissent, et elle disparait.
//
// Rien ici n'appelle l'API REAPER depuis le fil audio. GetSamples ne fait que
// demander au coeur de remplir un tampon, et convertir float -> ReaSample.
#pragma once

#include "reaper_plugin.h"
#include "../core/cp_engine.h"
#include "../core/cp_ring.h"

namespace cp {

// Un evenement MIDI en attente. POD strict : il traverse la frontiere de fil.
//
// EXPERIMENTAL — c'est la sonde de la question §12.9.1 : le bloc que REAPER nous
// tend porte un `midi_events` a cote des echantillons, mais rien dans le SDK ne
// dit si un apercu de PISTE transmet ce MIDI a la piste. Si oui, l'affranchissement
// du JSFX est total. Si non, on le saura en une soiree au lieu d'en discuter.
struct MidiEv {
  frame_t       at;      // frame absolu
  unsigned char msg[3];
};

class PortSource : public PCM_source {
 public:
  PortSource(Engine* eng, int port);
  ~PortSource() override;

  // --- PCM_source -----------------------------------------------------------
  PCM_source* Duplicate() override { return nullptr; } // jamais duplique
  bool IsAvailable() override { return true; }
  const char* GetType() override { return "CP_Port"; }
  bool SetFileName(const char*) override { return false; }
  int GetNumChannels() override { return kMaxChans; }
  double GetSampleRate() override { return eng_ ? eng_->srate() : 48000.0; }

  // Un apercu permanent n'a pas de fin. On ne rend pas l'infini (le SDK ne dit
  // pas ce que REAPER en ferait) mais une duree enorme : 1e9 secondes, soit
  // trente ans. C'est le point §9.3 a verifier a la sonde.
  double GetLength() override { return 1.0e9; }

  int PropertiesWindow(HWND) override { return 0; }

  void GetSamples(PCM_source_transfer_t* block) override;
  void GetPeakInfo(PCM_source_peaktransfer_t* block) override;

  void SaveState(ProjectStateContext*) override {}
  int  LoadState(const char*, ProjectStateContext*) override { return -1; }
  void Peaks_Clear(bool) override {}
  int  PeaksBuild_Begin() override { return 0; }
  int  PeaksBuild_Run() override { return 0; }
  void PeaksBuild_Finish() override {}

  // --- MIDI experimental (fil principal) ------------------------------------
  // Depose un evenement date. Rend false si la file est pleine.
  bool queue_midi(frame_t at, unsigned char s, unsigned char d1, unsigned char d2);

  // Combien d'evenements ont ete REMIS a REAPER. Si ce compteur monte et qu'on
  // n'entend rien, la reponse est « REAPER ne route pas le MIDI d'un apercu de
  // piste » — et c'est une reponse, pas un echec.
  int64_t midi_out() const { return midi_out_; }
  bool     midi_seen_list() const { return midi_list_seen_; }

  // --- diagnostic (lu depuis le fil principal) ------------------------------
  int      port() const { return port_; }
  int64_t  calls() const { return calls_; }
  double   last_time_s() const { return last_time_s_; }
  double   max_gap_s() const { return max_gap_s_; }
  int      last_len() const { return last_len_; }

 private:
  Engine*  eng_;
  int      port_;

  // Tampon de travail prealloue. AUCUNE allocation dans GetSamples : c'est la
  // contrainte du dossier, et le harnais la prouve deja cote coeur.
  sample_t* scratch_;
  int       scratch_frames_;

  // Instrumentation. `time_s` du bloc est un temps DEMANDE, pas un compteur
  // (§12.5.1) : on le journalise pour savoir si l'hote demande de facon
  // contigue et monotone. Si un jour il saute, c'est ici qu'on le verra, et non
  // dans une oreille.
  volatile int64_t calls_;
  volatile double  last_time_s_;
  volatile double  max_gap_s_;
  volatile int     last_len_;

  // MIDI en attente. L'anneau traverse la frontiere de fil ; le tableau
  // `pending_` n'est touche que par le fil audio, ce qui evite d'avoir besoin
  // d'une file qui sache regarder son premier element sans le retirer.
  SpscRing<MidiEv, 128> midi_in_;
  MidiEv           pending_[64];
  int              npending_;
  volatile int64_t midi_out_;
  volatile bool    midi_list_seen_;
};

} // namespace cp
