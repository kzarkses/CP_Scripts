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

namespace cp {

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
};

} // namespace cp
