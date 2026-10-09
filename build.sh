#!/bin/sh
# app.html(본문)을 감싸서 설치 가능한 index.html 을 만듭니다.
cd "$(dirname "$0")"
{
  echo '<!doctype html><html lang="ko"><head><meta charset="utf-8">'
  echo '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'
  echo '<meta name="theme-color" content="#16244F"><link rel="manifest" href="manifest.json"><link rel="icon" href="icon.svg"><link rel="apple-touch-icon" href="apple-touch-icon.png"><meta name="apple-mobile-web-app-title" content="기도의 촛불"><meta name="apple-mobile-web-app-capable" content="yes">'
  echo '<style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}[hidden]{display:none!important}img{max-width:100%}</style>'
  echo '</head><body>'
  echo '<script src="config.js"></script><script src="vendor/supabase.js"></script>'
  cat app.html
  echo '</body></html>'
} > index.html
