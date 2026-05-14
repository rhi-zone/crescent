@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -useb crescent.run/install.ps1 | iex"
