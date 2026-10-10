File {
  Grid = "diode_msh.tdr"
  Current = "diode_iv"
  Plot = "diode_fields"
  Output = "diode_solver"
}
Electrode {
  { Name="anode" Voltage=0.0 }
  { Name="cathode" Voltage=0.0 }
}
Physics {
  Fermi
  Mobility(DopingDep)
  Recombination(SRH)
}
Plot { Potential eDensity hDensity Doping ElectricField/Vector }
Math {
  Extrapolate
  RelErrControl
  Digits=5
  Iterations=30
  Number_of_Threads=1
}
Solve {
  Coupled(Iterations=100) { Poisson }
  Coupled { Poisson Electron Hole }
  Quasistationary(
    InitialStep=0.1 MinStep=1e-5 MaxStep=0.2
    Goal { Name="anode" Voltage=0.2 }
  ) { Coupled { Poisson Electron Hole } }
}
