"""
TALKSHOW — محرّك الرندر + interface web
----------------------------------------
Meme methode que Allo Chef (render_anim.py / render_synthe.py) :
capture frame par frame avec Playwright (SSAA x3), puis encodage :

    EXPORTS/TalkShow_<Name>.mov   -> QuickTime RLE, 1920x1080, canal ALPHA (montage)
    PREVIEW/TalkShow_<Name>.mp4   -> H.264 sur fond noir (lecture rapide / telephone)

Quality settings (copiés d'Allo Chef) :
    * supersampling x3 (5760x3240) puis ré-échantillonnage Lanczos vers 1920x1080
    * template V1b (Nom/Titre/Bug/Fullscreen) : timeline complete 5,0 s @ 50 i/s
      -> fade-in 400 ms (ease-out) + maintien -> coupe franche hors clip (HOLD_MS)
    * synthe INVITE (animation V2) : timeline complete 10,0 s @ 50 i/s
      -> entree 950 ms (delai 250 ms) + AFFICHAGE (hold) 7400 ms + sortie 850 ms
      + 550 ms cache = 10 000 ms = 500 images. Entree/sortie/coupe inchangees :
      seul l'affichage est rallonge (CLIP_INVITE_MS).

1. INTERFACE (recommande)
       double-clique sur  PANNEAU_DE_CONTROLE\\INTERFACE_WEB.bat
       -> lance le serveur local (port 8730) et ouvre la page
       -> 6 onglets (Invite / Nom / Titre / Bug / Fullscreen / Generique),
          apercu en direct du VRAI design, bouton GENERER
       -> produit EXPORTS/TalkShow_<X>.mov (alpha 1080i50 — 5,00 s,
          10,00 s pour l'Invite) + PREVIEW mp4
       Les marges mesurees s'affichent apres le rendu (mesure, sans jugement).

2. LIGNE DE COMMANDE
       python render_talkshow.py                 # rend tous les templates (contenu par defaut)
       python render_talkshow.py --only Nom
       python render_talkshow.py --frames 60      # test rapide
       python render_talkshow.py --serve          # interface web (ce que fait le .bat)
       python render_talkshow.py --serve --no-open

Aucun template officiel, ni talkshow.css, ni habillage.js n'est modifie :
le contenu est injecte dans un fichier de rendu temporaire, supprime apres coup.
"""

import argparse
import copy
import html as html_lib
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading

# les consoles Windows sont en cp1252 : on n'autorise jamais un crash d'ecriture
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

from playwright.sync_api import sync_playwright

# --- Configuration ----------------------------------------------------------
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
EXPORTS_DIR = os.path.join(BASE_DIR, "EXPORTS")
PREVIEW_DIR = os.path.join(BASE_DIR, "PREVIEW")
UI_PAGE = os.path.join(BASE_DIR, "TALKSHOW.html")
TMP_HTML = os.path.join(BASE_DIR, "_render_tmp.html")

TEMPLATES = {
    "invite":     {"file": "template_invite.html",     "label": "Master Invite", "out": "Invite",     "frames": 500},
    "nom":        {"file": "template_nom.html",        "label": "Nom simple",    "out": "Nom",        "frames": 250},
    "titre":      {"file": "template_titre.html",      "label": "Titre / Sujet", "out": "Titre",      "frames": 250},
    "bug":        {"file": "template_bug.html",        "label": "Bug permanent", "out": "Bug",        "frames": 250},
    "fullscreen": {"file": "template_fullscreen.html", "label": "Plein ecran",   "out": "Fullscreen", "frames": 250},
    # Invite : 500 images = clip du synthe (animation V2) de 10,00 s
    # (CLIP_INVITE_MS @ 50 i/s) — les 4 templates V1b gardent 250 / 5,00 s.
    # frames du genérique = repli uniquement — sa duree reelle est dynamique
    # (voir credits_duration_ms / credits_frames) : ~378 images au contenu
    # par defaut (defilement 5533 ms [trajet entier] + pause finale 2000 ms).
    "generique":  {"file": "template_generique.html",  "label": "Générique de fin", "out": "Generique", "frames": 250},
}

FPS = 50
DURATION = 5.0                      # secondes — clip des 4 templates V1b
TOTAL_FRAMES = int(FPS * DURATION)  # 250 images
# Synthe INVITE (animation V2) : duree cible 10 s mini -> 500 images @ 50 i/s.
# Hold par defaut 8600 ms : affichage 1200..8600 (7400 ms), sortie 8600..9450
# (850 ms, inchangee), cache 9450..10000 (550 ms, inchange) = 10 000 ms.
CLIP_INVITE_MS = 10000

SSAA = 3                            # supersampling (5760x3240 -> 1080p)
WIDTH, HEIGHT = 1920, 1080

HOST, PORT = "127.0.0.1", 8730      # 8730 : Allo Chef utilise 8720
URL = "http://%s:%d/" % (HOST, PORT)

# contenu par defaut = celui des templates officiels
DEFAULTS = {
    "invite": {
        "nom": "\u0645\u062d\u0645\u062f \u0623\u0645\u064a\u0646",
        "role": "\u0645\u0642\u062f\u0651\u0645 \u0627\u0644\u0628\u0631\u0646\u0627\u0645\u062c \u0648 \u0645\u062e\u0631\u062c TV",
        "badge_ar": "\u0636\u064a\u0641",
        "badge_la": "INVIT\u00c9",
    },
    "nom": {
        "nom": "\u0645\u062d\u0645\u062f \u0623\u0645\u064a\u0646",
        "role": "\u0645\u0642\u062f\u0651\u0645 \u0627\u0644\u0628\u0631\u0646\u0627\u0645\u062c \u0648 \u0645\u062e\u0631\u062c TV",
    },
    "titre": {
        "title_main": "الإصلاح الاقتصادي: كيف نخرج من الأزمة؟",
        "title_sub": "موضوع النقاش",
    },
    "bug": {
        "texte": "LIVE COOKING",
    },
    "fullscreen": {
        "tab": "\u0645\u0644\u062e\u0635 \u0627\u0644\u0646\u0642\u0627\u0634",
        "lead": "\u0623\u0628\u0631\u0632 \u0627\u0644\u0645\u0648\u0627\u0636\u064a\u0639 \u0627\u0644\u062a\u064a \u062a\u0646\u0627\u0648\u0644\u062a\u0647\u0627 \u0627\u0644\u062d\u0644\u0642\u0629",
        "textes": [
            "\u062a\u0631\u0643\u0651\u0632 \u0627\u0644\u0646\u0642\u0627\u0634 \u0639\u0644\u0649 \u0627\u0644\u0648\u0636\u0639 \u0627\u0644\u0627\u0642\u062a\u0635\u0627\u062f\u064a \u0627\u0644\u062d\u0627\u0644\u064a \u0648\u062a\u0623\u062b\u064a\u0631\u0647 \u0639\u0644\u0649 \u0627\u0644\u0642\u062f\u0631\u0629 \u0627\u0644\u0634\u0631\u0627\u0626\u064a\u0629 \u0644\u0644\u0623\u0633\u0631 \u0627\u0644\u062a\u0648\u0646\u0633\u064a\u0629\u060c \u0641\u0636\u0644\u0627\u064b \u0639\u0646 \u0645\u0644\u0641\u0651 \u0627\u0644\u0634\u0628\u0627\u0628 \u0648\u0627\u0644\u0628\u0637\u0627\u0644\u0629 \u0648\u0633\u0628\u0644 \u062e\u0644\u0642 \u0641\u0631\u0648\u0635 \u0639\u0645\u0644 \u062c\u062f\u064a\u062f\u0629\u060c \u0645\u0639 \u0645\u062d\u0627\u0648\u0644\u0629 \u062a\u0642\u062f\u064a\u0645 \u0645\u0642\u062a\u0631\u062d\u0627\u062a \u0639\u0645\u0644\u0629 \u0642\u0627\u0628\u0644\u0629 \u0644\u0644\u062a\u0637\u0628\u064a\u0642 \u0641\u064a \u0627\u0644\u0645\u0631\u062d\u0644\u0629 \u0627\u0644\u0645\u0642\u0628\u0644\u0629.",
            "\u0643\u0645\u0627 \u062e\u0651\u0635\u0651\u064a\u0635\u062a \u0641\u0642\u0631\u0629 \u0644\u062a\u062d\u0644\u064a\u0644 \u0627\u0644\u0648\u0639\u0648\u062f \u0627\u0644\u0627\u0646\u062a\u062e\u0627\u0628\u064a\u0629 \u0627\u0644\u062a\u064a \u062a\u0642\u062f\u0651\u0645\u0647\u0627 \u0627\u0644\u0623\u062d\u0632\u0627\u0628 \u0648\u0644\u0642\u064a\u0627\u0633 \u0645\u062f\u0649 \u0645\u0637\u0627\u0628\u0642\u062a\u0647\u0627 \u0644\u0648\u0627\u0642\u0639 \u0627\u0644\u0645\u0648\u0627\u0637\u0646 \u0627\u0644\u064a\u0648\u0645.",
        ],
    },
    # meme contenu que template_generique.html (marqueurs CR:START / CR:END)
    "generique": {
        "credits": ("# RÉALISATION\nMohamed Amine Djenadi\nAhmed\nKarim\n"
                    "# CAMÉRAS\nAli\nSamir\nNadir\n"
                    "# RÉGIE\nSofiane\nYacine"),
    },
}

# longueurs maximales (lelettre arabe large : protege le bloc compact)
LIMITS = {
    "invite": {"nom": 24, "role": 40, "badge_ar": 10, "badge_la": 12},
    "nom": {"nom": 24, "role": 40},
    "titre": {"title_main": 80, "title_sub": 50},
    "bug": {"texte": 30},
    "fullscreen": {"tab": 20, "lead": 70},
    "generique": {"credits": 6000},   # garde-fou : lignes illimitees en pratique
}
MAX_PARAS = 3           # paragraphes fullscreen
MAX_PARA_LEN = 240      # caracteres par paragraphe

# generique : constantes MIROIR des regles CSS isolees (.cr-* / track).
# Les line-height sont sans unite dans le CSS -> hauteur de ligne =
# valeur x font-size, exactement, quel que soit la police.
CR_CAT_LH = 1.2         # .cr-cat  { line-height: 1.2 }
CR_NAME_LH = 1.3        # .cr-name { line-height: 1.3 }
CR_BLOCK_GAP = 16       # .cr-block { gap: 16px }
CR_VH = 1080            # hauteur du canvas broadcast (depart du défilement)
CR_END_GAP = 64         # marge basse finale : a l'arret, bord bas du bloc =
                        # CR_VH - CR_END_GAP = 1016 px -> le DERNIER element
                        # reel reste visible (aucune position codee en dur).
                        # 64 >= 48 (resspiration du panneau ::before) + 16 px
                        # d'air -> panneau translucide entierement a l'ecran.
                        # MIROIR JS : var endGap de template_generique.html.
CR_CAT_MAX = 32         # caracteres par categorie (white-space: nowrap)
CR_NAME_MAX = 48        # caracteres par nom (white-space: nowrap)

# =============================================================================
#  PARAMETRES VISUELS — REGISTRE (source unique de verite)
# =============================================================================
# C'est CE registre que le serveur accepte, dans l'apercu ET dans le rendu
# (.mov) : les memes valeurs sont injectees par compose_html() aux deux.
# Toute cle absente du registre est ignoree (parametres SYSTEME proteges :
# --skew-angle, structure, positionnement, display, z-index, keyframes,
# easings, HOLD_MS, duree du clip, settings renderer).
# Les defauts = les valeurs exactement validees (V1b + animation V2).

COLOR_TOKENS = {
    "bg":         ("Couleur du panneau",       "--ts-bg",         "#16082B"),
    "name":       ("Couleur du nom",           "--ts-name-c",     "#FFFFFF"),
    "role_c":     ("Couleur de la fonction",   "--ts-role-c",     "#F5680A"),
    "badge_bg":   ("Fond du badge",            "--ts-badge-bg",   "#FFE600"),
    "badge_txt":  ("Texte du badge",           "--ts-badge-txt",  "#0A0414"),
    "border1":    ("Bordure Primaire",         "--ts-border1",    "#00E5FF"),
    "border2":    ("Bordure Secondaire",       "--ts-border2",    "#E2007A"),
    "glow":       ("Lumière / Ombre",          "--ts-glow-c",     "#00E5FF"),
    # --- Titre indépendant ---
    "title_bg_top":    ("Fond haut",           "--ts-title-bg-top",    "#182855"),
    "title_bg_bottom": ("Fond bas",            "--ts-title-bg-bottom", "#0C142A"),
    "title_text_main": ("Texte principal",     "--ts-title-text-main", "#FFFFFF"),
    "title_text_sub":  ("Texte secondaire",    "--ts-title-text-sub",  "#FFFFFF"),
    "title_separator": ("Séparateur",          "--ts-title-separator", "#FFFFFF"),
}

# =============================================================================
#  POLICES LOCALES — dossier assets/fonts/ (scan = source unique de verite)
# =============================================================================
# .ttf / .otf / .woff / .woff2. Un suffixe de graisse (-Regular, -SemiBold...)
# est rattache a la MEME famille ; un fichier sans suffixe = police variable
# (graisses 100 900). Le scan alimente le selecteur "Police" des 6 onglets
# (options dynamiques, une police independante par template) et les @font-face
# injectes par font_style() UNIQUEMENT si une police est choisie -> templates
# sans police personnalisee : sortie byte a byte identique (aucune regression).
FONTS_DIR = os.path.join(BASE_DIR, "assets", "fonts")
FONT_EXTS = (".ttf", ".otf", ".woff", ".woff2")
FONT_FORMATS = {".woff2": "woff2", ".woff": "woff",
                ".otf": "opentype", ".ttf": "truetype"}
FONT_WEIGHT_SUFFIX = {
    "thin": 100, "extralight": 200, "light": 300, "regular": 400, "normal": 400,
    "medium": 500, "semibold": 600, "bold": 700, "extrabold": 800, "black": 900,
}


def _font_label(stem):
    """NotoKufiArabic -> Noto Kufi Arabic (espaces sur les changements de casse)."""
    s = re.sub(r"[_\[\]]", " ", stem)
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def scan_fonts(directory=None):
    """{id: {id, label, family, files:[{file, weight}]}} pour chaque famille
    trouvee. directory parametrable (teste avec des dossiers temporaires).

    Normalisation : les variantes de nommage des editeurs
    (Alexandria-VariableFont_wght, Cairo[slnt,wght], Foo-VF...) sont rattachees
    a la MEME famille que les graisses statiques (Foo-Regular, Foo-Bold...)."""
    directory = directory or FONTS_DIR
    families = {}
    if not os.path.isdir(directory):
        return families
    for name in sorted(os.listdir(directory)):
        if not name.lower().endswith(FONT_EXTS):
            continue
        stem = os.path.splitext(name)[0]
        # variantes "VariableFont_wght" / "[slnt,wght]" -> famille de base
        base = re.sub(r"[-_ ]?Variable[-_ ]?Font.*$", "", stem, flags=re.I)
        base = re.sub(r"\[[^\]]*\]", "", base)
        base = re.sub(r"[-_ ]?VF$", "", base, flags=re.I).strip(" -_") or stem
        weight = None
        m = re.match(r"^(?P<b>.+?)[ _-](?P<w>[A-Za-z]+)$", base)
        if m and m.group("w").lower() in FONT_WEIGHT_SUFFIX:
            base, weight = m.group("b"), FONT_WEIGHT_SUFFIX[m.group("w").lower()]
        fid = re.sub(r"[^a-z0-9]", "", base.lower())
        if not fid:
            continue
        fam = families.setdefault(fid, {"id": fid, "label": _font_label(base),
                                        "family": base, "files": []})
        fam["files"].append({"file": name, "weight": weight})
    return families


FONT_FAMILIES = scan_fonts()
FONT_OPTIONS = ([("default", "Police actuelle (par défaut)")] +
                sorted([(f["id"], f["label"]) for f in FONT_FAMILIES.values()],
                       key=lambda x: x[1].lower()))


def _px(pid, group, label, css, default, vmin, vmax, step=1, unit="px"):
    return {"id": pid, "group": group, "label": label, "type": "number",
            "css": css, "default": default, "min": vmin, "max": vmax,
            "step": step, "unit": unit}


def _sel(pid, group, label, options, default, css=None):
    """select semantique : les valeurs sont traduites en CSS par _resolve_anim."""
    return {"id": pid, "group": group, "label": label, "type": "select",
            "css": css, "default": default, "options": options}


def _font_sel():
    """Selecteur « Police » : meme schema sur les 6 onglets, mais la valeur
    est STOCKEE par template (visualSel[tpl].font) -> Invite != Generique."""
    return _sel("font", "typographie", "Police", FONT_OPTIONS, "default",
                css="--ts-font-family")


def _colors(*ids):
    """ids : id simple ou (id, label) pour un libelle propre au template."""
    out = []
    for item in ids:
        cid, label = item if isinstance(item, tuple) else (item, COLOR_TOKENS[item][0])
        out.append({"id": cid, "group": "couleurs", "label": label,
                    "type": "color", "css": COLOR_TOKENS[cid][1],
                    "default": COLOR_TOKENS[cid][2]})
    return out


ANIM_TYPE_OPTS = [("mouvement", "Mouvement + fondu"), ("fondu", "Fondu seul")]
DIR_IN_OPTS = [("bas", "Depuis le bas"), ("haut", "Depuis le haut"),
               ("droite", "Depuis la droite"), ("gauche", "Depuis la gauche")]
DIR_OUT_OPTS = [("bas", "Vers le bas"), ("haut", "Vers le haut"),
                ("droite", "Vers la droite"), ("gauche", "Vers la gauche")]
DIR_MOVE = {"bas": "translateY(240px)", "haut": "translateY(-240px)",
            "droite": "translateX(240px)", "gauche": "translateX(-240px)"}

MODEL_OPTIONS = [
    # ("original",         "Original (Master V2)"), # Masqué de l'UI comme demandé, conservé en fallback
    ("minimal-ligne",    "Ligne Fine (Typo AE)"),
    ("minimal-cadre",    "Cadre Fin (Typo AE)"),
    ("minimal-vertical", "Ligne Gauche (Typo AE)"),
]

# ---- geometrie/taille communes ---------------------------------------------
_GEOM_INVITE = [
    _px("pos_x", "geometrie", "Position X (depuis la droite)", "--ts-pos-x", 90, 20, 400),
    _px("pos_y", "geometrie", "Position Y (depuis le bas)",     "--ts-pos-y", 60, 20, 400),
]
_SHADOW = [
    _px("shadow_x", "ombre", "Ombre — décalage X", "--ts-shadow-x", 8, 0, 24),
    _px("shadow_y", "ombre", "Ombre — décalage Y", "--ts-shadow-y", 8, 0, 24),
]
# Protection de lisibilité broadcast (distincte du glow décoratif) :
# Le wash ajoute une text-shadow diffuse derrière le texte pour qu'il reste
# lisible sur tout fond caméra, sans modifier la géométrie des glyphes.
# 2 paramètres suffisent : intensity pilote les opacités des couches,
# radius pilote la diffusion. Un 3e paramètre wash_y n'apporte rien de
# perceptible sur des polices arabes à hauts jambages — écarté pour simplifier.
_WASH = [
    # Défaut broadcast validé = 20 %. Valeur de secours pour plans très lumineux = 30 %.
    # Test non-régression : wash_intensity=0 → 0 pixel différent sur 18 662 400 (2026-10-02).
    _px("wash_intensity", "ombre", "Wash — Intensité (%)", "--ts-wash-intensity", 20, 0, 100, 5, ""),
    _px("wash_radius",    "ombre", "Wash — Diffusion (px)", "--ts-wash-radius",    6, 0, 20,  1, "px"),
]
_ANIM_INVITE = [
    _px("in_delay", "animation", "Délai avant entrée (ms)", "--ts-in-delay", 250, 0, 1000, 10, "ms"),
    _px("in_dur",   "animation", "Durée de l'entrée (ms)", "--ts-in-dur",   950, 300, 2000, 10, "ms"),
    _px("hold",     "animation", "Durée d'affichage — début de sortie (ms)", "--ts-hold", 8600, 500, 9500, 10, "ms"),
    _px("out_dur",  "animation", "Durée de la sortie (ms)", "--ts-out-dur",  850, 300, 1600, 10, "ms"),
]
_ANIM_INVITE_SELECTS = [
    _sel("anim_in_type", "animation", "Type d'entrée", ANIM_TYPE_OPTS, "mouvement"),
    _sel("anim_in_dir",  "animation", "Direction de l'entrée", DIR_IN_OPTS, "bas"),
    _sel("anim_out_type", "animation", "Type de sortie", ANIM_TYPE_OPTS, "mouvement"),
    _sel("anim_out_dir",  "animation", "Direction de la sortie", DIR_OUT_OPTS, "bas"),
]
_FADE = [
    _px("fade_dur", "animation", "Durée de l'entrée — fondu (ms)", "--ts-fade-dur", 400, 100, 1500, 10, "ms"),
]

VISUAL = {
    "invite": {
        "colors": _colors("bg", "name", "role_c", "badge_bg", "badge_txt", "border1", "border2", "glow"),
        "numbers": (_GEOM_INVITE +
                    [_px("bg_alpha", "couleurs", "Opacité du fond (%)", "--ts-bg-alpha", 100, 0, 100, 1, ""),
                     _px("name_size", "typographie", "Taille du nom", "--ts-name-size", 72, 40, 120),
                     _px("role_size", "typographie", "Taille de la fonction", "--ts-role-size", 36, 16, 60),
                     _px("chip_size", "typographie", "Taille du badge latin", "--ts-chip-size", 24, 12, 48),
                     _px("glow", "ombre", "Intensité lumineuse (%)", "--ts-glow-intensity", 0, 0, 100, 5, "")]
                    + _SHADOW + _WASH + _ANIM_INVITE),
        "selects": [_font_sel(), _sel("model", "geometrie", "Modèle de synthé", MODEL_OPTIONS, "original")] + _ANIM_INVITE_SELECTS,
    },
    "nom": {
        "colors": _colors("bg", "name", "role_c", "border1", "border2", "glow"),
        "numbers": (_GEOM_INVITE +
                    [_px("bg_alpha", "couleurs", "Opacité du fond (%)", "--ts-bg-alpha", 100, 0, 100, 1, ""),
                     _px("name_size", "typographie", "Taille du nom", "--ts-name-size", 72, 40, 120),
                     _px("role_size", "typographie", "Taille de la fonction", "--ts-role-size", 36, 16, 60)]
                    + _SHADOW + _WASH + _FADE),
        "selects": [_font_sel()],
    },
    "titre": {
        "colors": _colors("title_bg_top", "title_bg_bottom", "title_text_main", "title_text_sub", "title_separator"),
        "numbers": ([
            _px("title_bg_top_alpha", "opacites", "Opacité fond haut (%)", "--ts-title-bg-top-alpha", 85, 0, 100, 1, ""),
            _px("title_bg_bottom_alpha", "opacites", "Opacité fond bas (%)", "--ts-title-bg-bottom-alpha", 85, 0, 100, 1, ""),
            _px("title_main_size", "typographie", "Taille principal", "--ts-title-main-size", 58, 30, 120),
            _px("title_sub_size", "typographie", "Taille secondaire", "--ts-title-sub-size", 36, 20, 60),
            _px("title_pos_y", "geometrie", "Position Y (px depuis le bas)", "--ts-title-pos-y", 120, 0, 800),
            _px("title_band_top_height", "geometrie", "Hauteur bandeau haut", "--ts-title-band-top-h", 88, 40, 200),
            _px("title_band_bottom_height", "geometrie", "Hauteur bandeau bas", "--ts-title-band-bottom-h", 55, 20, 150),
            _px("title_separator_height", "geometrie", "Épaisseur séparateur", "--ts-title-separator-h", 1, 0, 20),
            _px("show_title_top", "visibilite", "Afficher bandeau haut (1=Oui 0=Non)", "--ts-show-title-top", 1, 0, 1, 1, "")
        ] + _WASH + _FADE),
        "selects": [_font_sel()],
    },
    "bug": {
        "colors": _colors("badge_bg", "badge_txt"),
        "numbers": [
            _px("pos_x", "geometrie", "Position X (depuis la gauche)", "--ts-pos-x", 90, 20, 400),
            _px("pos_y", "geometrie", "Position Y (depuis le bas)",   "--ts-pos-y", 60, 20, 400),
            _px("name_size", "typographie", "Taille du texte", "--ts-name-size", 45, 20, 80),
        ] + _FADE,
        "selects": [_font_sel()],
    },
    "fullscreen": {
        "colors": _colors("bg", "name", "role_c", "badge_bg", "badge_txt", "border1", "border2", "glow"),
        "numbers": [
            _px("pos_x", "geometrie", "Position X (marges gauche/droite)", "--ts-pos-x", 90, 20, 400),
            _px("fs_top", "geometrie", "Position Y — marge haute", "--ts-fs-top", 120, 40, 300),
            _px("fs_bottom", "geometrie", "Position Y — marge basse", "--ts-fs-bottom", 100, 40, 300),
            _px("fs_content_max", "typographie", "Largeur du contenu (px)", "--ts-fs-content-max", 1480, 600, 1480),
            _px("lead_size", "typographie", "Taille du lead", "--ts-lead-size", 54, 20, 70),
            _px("text_size", "typographie", "Taille du texte", "--ts-text-size", 32, 14, 50),
        ] + _SHADOW + _WASH + _FADE,
        "selects": [_font_sel()],
    },
    # 6e template : VISUAL dedie -> la whitelist sanitize_visual() verrouille
    # exactement ces cles. group: geometrie/typographie/animation = groupes de
    # buildParams() ; "couleurs" = section "Couleurs & palette" du panneau
    # (buildColors y rend aussi les NOMBRES de ce groupe : l'opacite).
    # 4 controles couleur/alpha demandes : Couleur du panneau (rapporte en
    # vraie transparence rgba() par credits_style), Opacite 0-100 %,
    # Couleur des categories, Couleur des noms. Plus de "bg" plein ecran :
    # le canvas devient ALPHA, la video passe derriere le panneau translucide.
    "generique": {
        "colors": [
            {"id": "panel", "group": "couleurs", "label": "Couleur du panneau",
             "type": "color", "css": "--ts-cred-panel", "default": "#0A0414"},
        ] + _colors(("border2", "Couleur des catégories"), ("name", "Couleur des noms")),
        "numbers": [
            _px("panel_alpha", "couleurs", "Opacité du panneau (alpha)", "--ts-cred-panel-alpha", 75, 0, 100, 1, "%"),
            _px("roll_speed", "animation", "Vitesse du défilement", "--ts-cred-speed", 150, 50, 400, 1, "px/s"),
            # pause AJOUTEE apres l'arret (jamais dediee au defilement) :
            # duree totale = defilement + hold*1000 — voir credits_duration_ms
            _px("hold", "animation", "Pause finale sur le dernier élément", "--ts-cred-hold", 2, 0, 5, 0.5, "s"),
            _px("cat_size", "typographie", "Taille catégorie", "--ts-cat-size", 40, 24, 60),
            _px("name_size", "typographie", "Taille noms", "--ts-name-size", 36, 20, 50),
            _px("spacing", "geometrie", "Espacement entre blocs", "--ts-spacing", 60, 20, 120),
            _px("glow", "ombre", "Intensité lumineuse (%)", "--ts-glow-intensity", 0, 0, 100, 5, ""),
        ],
        "selects": [
            _font_sel(),
            _sel("align_x", "geometrie", "Position horizontale",
                 [("left", "Gauche"), ("center", "Centre"), ("right", "Droite")],
                 "center", css="--ts-align-x"),
        ],
    },
}

GROUP_LABELS = {"couleurs": "COULEURS", "geometrie": "POSITION",
                "typographie": "TAILLES / TYPOGRAPHIE",
                "ombre": "OMBRE", "animation": "ANIMATION"}


def visual_defs(tpl):
    d = VISUAL.get(tpl) or VISUAL["invite"]
    return d["colors"] + d["numbers"] + d["selects"]


def visual_defaults(tpl):
    return {d["id"]: d["default"] for d in visual_defs(tpl)}


_HEX6 = re.compile(r"^#?[0-9a-fA-F]{6}$")
_HEX3 = re.compile(r"^#?[0-9a-fA-F]{3}$")

# Mode VIDE du panneau de controle : valeur explicite "aucun fond", distincte
# de toute couleur (un #FFFFFF reste un blanc opaque, jamais interprete comme
# du vide). N'accepte QUE la couleur de fond "bg" -> --pop-bg: transparent.
_VIDE_BG = ("transparent",)


def _color_value(value):
    s = str(value).strip()
    if _HEX6.match(s):
        return ("#" + s.lstrip("#")).upper()
    if _HEX3.match(s):
        return ("#" + "".join(ch * 2 for ch in s.lstrip("#"))).upper()
    return None


def sanitize_visual(tpl, params):
    """Whitelist stricte -> dict {id: valeur validee}. Toute autre cle est perdue."""
    if not isinstance(params, dict):
        return {}
    defs = {d["id"]: d for d in visual_defs(tpl)}
    clean = {}
    for key in defs:
        if key not in params:
            continue
        d, raw = defs[key], params[key]
        if d["type"] == "color":
            # Mode VIDE (option explicite du panneau) : uniquement "bg" peut
            # valoir "transparent" -> aucun calque de fond derriere le texte.
            # Toute autre couleur reste HEX stricte : #FFFFFF = blanc reel.
            if d["id"] == "bg" and str(raw).strip().lower() in _VIDE_BG:
                clean[key] = "transparent"
                continue
            val = _color_value(raw)
            if val:
                clean[key] = val
        elif d["type"] == "number":
            try:
                num = float(str(raw).replace(",", "."))
            except (TypeError, ValueError):
                continue
            step = float(d["step"])
            num = round(num / step) * step
            num = min(max(num, float(d["min"])), float(d["max"]))
            clean[key] = int(num) if step >= 1 else num
        elif d["type"] == "select":
            allowed = [opt[0] for opt in d["options"]]
            clean[key] = raw if raw in allowed else d["default"]
    return clean


def _resolve_anim(tpl, clean):
    """Type + direction -> variable CSS (translate / none)."""
    if "anim_in_type" not in clean and "anim_in_dir" not in clean \
            and "anim_out_type" not in clean and "anim_out_dir" not in clean:
        return
    d = {x["id"]: x for x in visual_defs(tpl)}
    in_type = clean.get("anim_in_type", d["anim_in_type"]["default"])
    in_dir = clean.get("anim_in_dir", d["anim_in_dir"]["default"])
    out_type = clean.get("anim_out_type", d["anim_out_type"]["default"])
    out_dir = clean.get("anim_out_dir", d["anim_out_dir"]["default"])
    clean["anim_in_type"], clean["anim_in_dir"] = in_type, in_dir
    clean["anim_out_type"], clean["anim_out_dir"] = out_type, out_dir
    clean["--ts-in-from"] = "none" if in_type == "fondu" else DIR_MOVE[in_dir]
    clean["--ts-out-to"] = "none" if out_type == "fondu" else DIR_MOVE[out_dir]


def _resolve_model(tpl, clean):
    """Modèle de synthé Invite (model) -> variable CSS --ts-model-name."""
    if tpl != "invite":
        return
    d = {x["id"]: x for x in visual_defs(tpl)}
    m = clean.get("model", clean.get("shape", d["model"]["default"] if "model" in d else "original"))
    clean["model"] = m
    clean["--ts-model-name"] = m


def _clamp_anim(tpl, clean):
    """Invariant V2 : entree complete avant la sortie, sortie finie avant la
    fin du clip Invite (CLIP_INVITE_MS = 10 000 ms / 500 images @ 50 i/s)."""
    if "hold" not in clean and "out_dur" not in clean \
            and "in_dur" not in clean and "in_delay" not in clean:
        return
    out_dur = int(clean.get("out_dur", 850))
    in_delay = int(clean.get("in_delay", 250))
    in_dur = int(clean.get("in_dur", 950))
    hi = CLIP_INVITE_MS - out_dur
    lo = min(hi, in_delay + in_dur)
    clean["hold"] = min(max(int(clean.get("hold", 8600)), lo), hi)


def visual_style(tpl, params):
    """<style> :root { --var: valeur } pour les seuls parametres whitelistes.
    Retourne "" quand aucun parametre visuel n'est fourni -> sortie identique
    au pipeline historique (aucune emission inutile)."""
    clean = sanitize_visual(tpl, params)
    if not clean:
        return ""
    _resolve_anim(tpl, clean)
    _resolve_model(tpl, clean)
    _clamp_anim(tpl, clean)
    lines, seen = [], set()

    def emit(var, value):
        if var in seen or not value:
            return
        seen.add(var)
        lines.append("  %s: %s;" % (var, value))

    for d in visual_defs(tpl):
        if d["id"] not in clean:
            continue
        if d["type"] == "color":
            emit(d["css"], clean[d["id"]])
        elif d["type"] == "number":
            emit(d["css"], "%s%s" % (clean[d["id"]], d["unit"]))
    emit("--ts-in-from", clean.get("--ts-in-from") or "")
    emit("--ts-out-to", clean.get("--ts-out-to") or "")
    emit("--ts-model-name", clean.get("--ts-model-name") or "")
    if not lines:
        return ""
    return ('<style id="ts-params">\n:root {\n%s\n}\n</style>\n'
            % "\n".join(lines))


def font_style(tpl, params):
    """<style> de la police personnalisee : @font-face generes depuis le scan
    d'assets/fonts/ + application au canvas (seule la police choisie change,
    la geometrie/les tailles ne bougent pas).

    Vide si la police par defaut est choisie -> compose_html() des 5 templates
    reste IDENTIQUE (aucune emission inutile, empreintes inchangees).

    La pile de repli garde les familles declarees dans talkshow.css
    ('Kufi' / 'IBMPlexArabic' arabe + 'Montserrat' latin) : une police sans
    glyphe arabe retombe sur Kufi -> RTL/arabe conserves, aucun changement de
    mise en page induit."""
    clean = sanitize_visual(tpl, params)
    fid = clean.get("font", "default")
    fam = FONT_FAMILIES.get(fid) if fid else None
    if not fam:
        return ""

    # un @font-face par graisse ; formats dans l'ordre de qualite decroissante
    by_weight = {}
    for f in fam["files"]:
        by_weight.setdefault(f["weight"], []).append(f["file"])
    prio = [".woff2", ".woff", ".otf", ".ttf"]
    faces = []
    for weight in sorted(by_weight, key=lambda w: (w is None, w or 0)):
        files = sorted(by_weight[weight],
                       key=lambda n: prio.index(os.path.splitext(n)[1].lower()))
        src = ",\n         ".join(
            "url('assets/fonts/%s') format('%s')"
            % (n, FONT_FORMATS[os.path.splitext(n)[1].lower()]) for n in files)
        faces.append("@font-face {\n"
                     "    font-family: '%s';\n"
                     "    src: %s;\n"
                     "    font-weight: %s;\n"
                     "    font-style: normal;\n"
                     "    font-display: block;\n"
                     "}" % (fam["family"].replace("'", "\\'"), src,
                            weight if weight else "100 900"))
    stack = ["'%s'" % fam["family"].replace("'", "\\'"),
             "'Kufi'", "'IBMPlexArabic'", "'Montserrat'", "sans-serif"]
    return ('<style id="ts-font">\n%s\n'
            ':root {\n  --ts-font-family: %s;\n}\n'
            '.canvas, .canvas *, .canvas::before, .canvas::after, '
            '.canvas *::before, .canvas *::after '
            '{ font-family: var(--ts-font-family) !important; }\n'
            '</style>\n' % ("\n".join(faces), ", ".join(stack)))


FONT_PRELOAD = """
Promise.all([
  // .ts-name — Kufi 700, 72px (Invite / Nom / variantes minimal)
  document.fonts.load('700 72px Kufi', '\u0645\u062d\u0645\u062f \u0623\u0645\u064a\u0646'),
  // .ts-badge-ar — Kufi 700, 34px (badge arabe fixe dans template_invite)
  document.fonts.load('700 34px Kufi', '\u0636\u064a\u0641'),
  // .ts-title — Kufi 700, 60px (template_titre)
  document.fonts.load('700 60px Kufi', '\u0643\u064a\u0641 \u0646\u062e\u0631\u062c \u0645\u0646 \u0627\u0644\u0623\u0632\u0645\u0629'),
  // .ts-kicker — Kufi 700, 30px (template_titre, kicker = label sujet)
  document.fonts.load('700 30px Kufi', '\u0645\u0648\u0636\u0648\u0639 \u0627\u0644\u0646\u0642\u0627\u0634'),
  // .cr-cat — Kufi 700, 40px (template_generique categories)
  document.fonts.load('700 40px Kufi', '\u0623\u0628\u0631\u0632 \u0627\u0644\u0645\u0648\u0627\u0636\u064a\u0639'),
  // .ts-role / .cr-name — IBMPlexArabic 600, 36px (fonction + noms generique)
  document.fonts.load('600 36px IBMPlexArabic', '\u0645\u0642\u062f\u0651\u0645 \u0627\u0644\u0628\u0631\u0646\u0627\u0645\u062c \u0648 \u0645\u062e\u0631\u062c TV'),
  // .ts-badge-la — Montserrat 700, 24px (badge latin — chip_size défaut)
  document.fonts.load('700 24px Montserrat', 'TALKSHOW')
]).then(() => document.fonts.ready)
"""

# Verification AVANT la 1re capture : toutes les @font-face declarees dans le
# document (dont la police personnalisee eventuelle) doivent etre chargees ->
# aucun rendu .mov avec une police de repli. Renvoie la liste des familles
# non chargees (liste vide = OK).
FONT_WAIT = """
(async () => {
  const sample = "Aa Bb 123 \\u0645\\u0645 \\u0639\\u0639";
  const faces = [...document.fonts];
  const key = (ff) => (/^[0-9]+$/.test(String(ff.weight)) ? ff.weight : "400");
  for (const ff of faces) {
    try { await document.fonts.load(ff.style + " " + key(ff) + ' 48px "' + ff.family + '"', sample); }
    catch (e) {}
  }
  try { await document.fonts.ready; } catch (e) {}
  return faces.filter(ff => {
    try { return !document.fonts.check(key(ff) + ' 48px "' + ff.family + '"'); }
    catch (e) { return false; }
  }).map(ff => ff.family + "/" + ff.weight);
})()
"""



def run_ffmpeg_progress(cmd, total, label):
    import subprocess
    import sys
    print(f"  -> Encodage {label}...")
    p = subprocess.Popen(cmd, stderr=subprocess.PIPE, universal_newlines=True)
    for line in p.stderr:
        if "frame=" in line:
            import re
            m = re.search(r"frame=\s*(\d+)", line)
            if m:
                f = int(m.group(1))
                pct = min(100, int((f / total) * 100))
                bar_len = 30
                filled = int(bar_len * pct / 100)
                bar = '█' * filled + '-' * (bar_len - filled)
                sys.stdout.write(f"\r     [{bar}] {pct}%")
                sys.stdout.flush()
    p.wait()
    if p.returncode == 0:
        bar = '█' * 30
        sys.stdout.write(f"\r     [{bar}] 100% -> TERMINE AVEC SUCCES !\n")
    else:
        sys.stdout.write(f"\r     [ERREUR D'ENCODAGE]\n")
    sys.stdout.flush()

def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# =============================================================================
#  Injection du contenu (les templates officiels ne sont JAMAIS modifies)
# =============================================================================
def clean_text(value, limit):
    """Texte saisi par l'utilisateur : ni balise HTML, ni caractere de controle."""
    text = re.sub(r"<[^>]*>", "", str(value if value is not None else ""))
    text = re.sub(r"[\x00-\x1f\x7f]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def _set_text(src, cls, value):
    pat = re.compile(r'(class="%s"[^>]*>)[^<]*(</)' % re.escape(cls))
    new, n = pat.subn(lambda m: m.group(1) + html_lib.escape(value) + m.group(2), src)
    if not n:
        print("[avertissement] marqueur %s introuvable" % cls)
    return new


def _set_fs_texts(src, values):
    blocks = list(re.finditer(r'[ \t]*<div class="fs-text"[^>]*>.*?</div>', src, re.S))
    if not blocks:
        print("[avertissement] marqueur fs-text introuvable")
        return src
    new = "\n".join('<div class="fs-text" lang="ar">%s</div>' % html_lib.escape(v)
                    for v in values)
    return src[:blocks[0].start()] + new + src[blocks[-1].end():]


# =============================================================================
#  GENERIQUE : contenu structure + duree dynamique (6e template)
# =============================================================================
# Python et JavaScript utilisent la MEME formule :
#     distance = 1080 + hauteur du contenu
#     duree_ms = distance / vitesse * 1000
# La hauteur est deterministe (une ligne = une ligne : white-space nowrap +
# line-height numeriques, marges/padding nuls) -> pas de mesure navigateur.
# La duree est injectee dans le HTML sous --ts-cred-dur : le navigateur ne
# recalcule rien au rendu -> duree Python == duree navigateur, image pour
# image, apercu et .mov identiques.
def _credits_raw(params):
    """Contenu brut : chaine multiligne (CLI/defaut) ou lignes du panneau.
    Repli sur le defaut si le contenu parse serait vide — meme logique que
    `... or DEFAULTS[...]` des autres templates. Point unique : compose_html()
    ET credits_duration_ms() passent par ici -> duree et contenu coherents."""
    raw = params.get("credits") if isinstance(params, dict) else None
    if raw is None or raw == "" or raw == []:
        raw = DEFAULTS["generique"]["credits"]
    if isinstance(raw, (list, tuple)):
        raw = "\n".join(str(x) for x in raw)
    raw = str(raw)[:LIMITS["generique"]["credits"]]
    if not parse_credits(raw):
        raw = DEFAULTS["generique"]["credits"]
    return raw


def parse_credits(raw):
    """'# Categorie' = categorie, sinon nom ; lignes vides ignorees.
    Nombre de lignes et de noms illimite. Retourne [(cat|None, [noms...])]."""
    blocks, cur = [], None
    for line in str(raw).split("\n"):
        s = line.strip()
        if not s:
            continue
        if s.startswith("#"):
            title = clean_text(s.lstrip("#").strip(), CR_CAT_MAX)
            if not title:
                continue
            cur = [title, []]
            blocks.append(cur)
        else:
            name = clean_text(s, CR_NAME_MAX)
            if not name:
                continue
            if cur is None:            # noms avant la premiere categorie
                cur = [None, []]
                blocks.append(cur)
            cur[1].append(name)
    return [(cat, list(names)) for cat, names in blocks]


def credits_html(blocks):
    """[(categorie, noms)] -> balises .cr-block / .cr-cat / .cr-name
    (texte utilisateur echappe : html_lib.escape, strictement)."""
    out = []
    for cat, names in blocks:
        out.append('                <div class="cr-block">')
        if cat:
            out.append('                    <div class="cr-cat">%s</div>'
                       % html_lib.escape(cat))
        for nm in names:
            out.append('                    <div class="cr-name">%s</div>'
                       % html_lib.escape(nm))
        out.append('                </div>')
    return "\n".join(out)


def _set_credits(src, html):
    """Remplace le contenu entre les marqueurs CR:START / CR:END (reperables)."""
    pat = re.compile(r"(<!--CR:START-->).*?(<!--CR:END-->)", re.S)
    new, n = pat.subn(lambda m: m.group(1) + "\n" + html + "\n                " + m.group(2),
                      src)
    if not n:
        print("[avertissement] marqueur CR:START/CR:END introuvable")
    return new


def credits_height(blocks, cat_size, name_size, spacing):
    """Hauteur exacte du track — MIROIR des regles CSS isolees du generique :
    bloc = categorie (x 1.2) + noms (x 1.3) + gap interne 16 px entre les
    enfants, track = somme des blocs + gap inter-blocs (spacing). Aucune
    marge ni padding vertical (gap seulement) -> somme exacte."""
    total = 0.0
    for cat, names in blocks:
        kids = (1 if cat else 0) + len(names)
        if kids == 0:
            continue
        if cat:
            total += cat_size * CR_CAT_LH
        total += len(names) * name_size * CR_NAME_LH
        total += (kids - 1) * CR_BLOCK_GAP
    if len(blocks) > 1:
        total += (len(blocks) - 1) * spacing
    return total


def credits_duration_ms(params=None):
    """Duree totale du generique (ms) — SOURCE UNIQUE Python/JS : defilement
    + PAUSE FINALE (hold, secondes).

    Defilement = trajet ENTIER / vitesse * 1000, avec l'ARRONDI DE L'ARRIVEE
    identique au JavaScript (ECMAScript : Math.round(x) == floor(x + 0.5)) :
    le bloc s'arrete quand son bord bas atteint CR_VH - CR_END_GAP (= 1016 px,
    au px entier pres) — le dernier element reel du contenu est arrive a sa
    position finale VISIBLE et l'animation s'y fige (plus aucun defilement).
    Positions ENTIERES a tout instant (miroir steps(1 px) de
    template_generique.html) -> aucune position fractionnaire a l'echelle
    device -> pas de scintillement de sous-pixel (netete « synthe »).

    Hold = AJOUTE apres l'arret, jamais dedie au defilement : la vitesse
    (roll_speed) est inchangee, les images supplementaires sont figees sur le
    dernier element. Par defaut 2 s (registre VISUAL["generique"] : hold,
    borne 0 a 5 s, pas 0,5 s) — parametre modifiable dans le panneau.

    Defaut : arrivee = round(1080 - 766,4 - 64) = 250 px, trajet = 830 px
    / 150 px/s = 5533,33 ms + 2000 ms de pause -> 7533,33 ms."""
    clean = sanitize_visual("generique", params)
    v = visual_defaults("generique")
    v.update(clean)
    h = credits_height(parse_credits(_credits_raw(params)),
                       v["cat_size"], v["name_size"], v["spacing"])
    # miroir exact de Math.round() JS : meme endY, meme trajet, deux moteurs
    end_y = int(math.floor((CR_VH - h - CR_END_GAP) + 0.5))
    dist = CR_VH - end_y               # trajet entier (toujours >= CR_END_GAP)
    roll = dist / float(v["roll_speed"]) * 1000.0
    return roll + float(v["hold"]) * 1000.0


def credits_frames(params=None):
    """images = ceil(duree_ms / 20) + 1 (20 ms = 1000/FPS) : le dernier temps
    scrubbé (frames - 1) * 20 ms est au moins la duree complete -> les DERNIERS
    plans du .mov sont figes sur le bloc arrete a sa position finale
    (defilement + pause finale).
    Defaut : 7533,33 ms (trajet entier 830 px -> 5533 ms de defilement +
    2000 ms de pause) -> 378 images (et non 250)."""
    return int(math.ceil(credits_duration_ms(params) / (1000.0 / FPS))) + 1


def template_frames(tpl, params=None, frames=None):
    """Images a rendre : valeur forcee > duree dynamique (generique) >
    registre. Inchange pour les 5 templates historiques (250 = 5,00 s)."""
    if frames:
        return int(frames)
    if tpl == "generique":
        return credits_frames(params)
    return int(TEMPLATES[tpl]["frames"])


def credits_style(params):
    """<style> du generique : panneau translucide en vraie transparence
    rgba() + couleurs POP TV + --ts-cred-dur (duree TOTALE calculee :
    defilement + pause finale) + --ts-cred-hold (pause en ms) + les variables
    visuelles. TOUJOURS emise, defauts inclus (a la difference de
    visual_style, qui n'emmet que si des parametres arrivent) : --ts-name-size
    est un jeton partage (72 px pour Invite, defini dans :root de
    talkshow.css), donc sans cette emission explicite le repli 36 px de
    .cr-name ne s'appliquerait jamais. Injection avant </head>, donc APRES la
    feuille de style : cette :root gagne par ordre (memes specificites)."""
    clean = sanitize_visual("generique", params)
    v = visual_defaults("generique")
    v.update(clean)
    lines = []
    for d in visual_defs("generique"):       # couleurs d'abord (miroir visual_style)
        if d["type"] != "color":
            continue
        if d["id"] == "panel":
            # couleur + opacite -> UNE vraie transparence CSS rgba()
            # (pas de couleur opaque : la video/camera passe derriere)
            hexv = _color_value(v["panel"]) or d["default"]
            rr, gg, bb = int(hexv[1:3], 16), int(hexv[3:5], 16), int(hexv[5:7], 16)
            alpha = max(0.0, min(100.0, float(v["panel_alpha"]))) / 100.0
            lines.append("  --ts-cred-panel: rgba(%d, %d, %d, %g);"
                         % (rr, gg, bb, alpha))
        else:
            lines.append("  %s: %s;" % (d["css"], v[d["id"]]))
    lines += [
        "  --ts-cred-dur: %.0fms;" % credits_duration_ms(params),
        # pause finale en ms (defilement = --ts-cred-dur - --ts-cred-hold)
        "  --ts-cred-hold: %.0fms;" % (float(v["hold"]) * 1000.0),
        "  --ts-cred-speed: %d;" % v["roll_speed"],
        "  --ts-cat-size: %dpx;" % v["cat_size"],
        "  --ts-name-size: %dpx;" % v["name_size"],
        "  --ts-spacing: %dpx;" % v["spacing"],
        "  --ts-align-x: %s;" % v["align_x"],
    ]
    return ('<style id="ts-cred-params">\n:root {\n%s\n}\n</style>\n'
            % "\n".join(lines))


def compose_html(tpl, params=None):
    """Compose le HTML du template : contenu injecte + parametres visuels.
    Le fichier source n'est JAMAIS modifie ; apercu et rendu .mov passent
    par ici -> exactement les memes valeurs dans les deux cas."""
    info = TEMPLATES.get(tpl) or TEMPLATES["invite"]
    path = os.path.join(BASE_DIR, info["file"])
    with io.open(path, encoding="utf-8") as fh:
        src = fh.read()

    p = dict(DEFAULTS.get(tpl, {}))
    p.update(params or {})
    lim = LIMITS.get(tpl, {})

    if tpl == "invite":
        m = str(p.get("model", p.get("shape", "original"))).strip().lower()
        allowed = [opt[0] for opt in MODEL_OPTIONS] + ["original"]
        if m not in allowed:
            m = "original"
        if m != "original":
            src = src.replace('<div class="ts-lower">', f'<div class="ts-lower" data-model="{html_lib.escape(m)}">', 1)
        src = _set_text(src, "ts-badge-ar", clean_text(p.get("badge_ar"), lim["badge_ar"]) or DEFAULTS["invite"]["badge_ar"])
        src = _set_text(src, "ts-badge-la", clean_text(p.get("badge_la"), lim["badge_la"]) or DEFAULTS["invite"]["badge_la"])
        src = _set_text(src, "ts-name", clean_text(p.get("nom"), lim["nom"]) or DEFAULTS["invite"]["nom"])
        src = _set_text(src, "ts-role", clean_text(p.get("role"), lim["role"]) or DEFAULTS["invite"]["role"])
    elif tpl == "nom":
        src = _set_text(src, "ts-name", clean_text(p.get("nom"), lim["nom"]) or DEFAULTS["nom"]["nom"])
        src = _set_text(src, "ts-role", clean_text(p.get("role"), lim["role"]) or DEFAULTS["nom"]["role"])
    elif tpl == "titre":
        src = _set_text(src, "ts-titleband-main", clean_text(p.get("title_main"), lim["title_main"]) or DEFAULTS["titre"]["title_main"])
        src = _set_text(src, "ts-titleband-sub", clean_text(p.get("title_sub"), lim["title_sub"]) or DEFAULTS["titre"]["title_sub"])
        if int(p.get("show_title_top", 1)) == 0:
            src = src.replace('class="ts-titleband"', 'class="ts-titleband hide-top"')
    elif tpl == "bug":
        src = _set_text(src, "ts-bug-text", clean_text(p.get("texte"), lim["texte"]) or DEFAULTS["bug"]["texte"])
    elif tpl == "fullscreen":
        src = _set_text(src, "ts-badge-ar", clean_text(p.get("tab"), lim["tab"]) or DEFAULTS["fullscreen"]["tab"])
        src = _set_text(src, "fs-lead", clean_text(p.get("lead"), lim["lead"]) or DEFAULTS["fullscreen"]["lead"])
        raw = p.get("textes")
        if isinstance(raw, str):
            raw = [ln for ln in raw.split("\n")]
        paras = []
        for item in (raw or []):
            t = clean_text(item, MAX_PARA_LEN)
            if t:
                paras.append(t)
            if len(paras) >= MAX_PARAS:
                break
        if not paras:
            paras = list(DEFAULTS["fullscreen"]["textes"])
        src = _set_fs_texts(src, paras)
    elif tpl == "generique":
        # texte structure (# = categorie) -> HTML .cr-block echappe, injecte
        # entre les marqueurs du template (fichier source jamais modifie)
        src = _set_credits(src, credits_html(parse_credits(_credits_raw(p))))

    if tpl == "generique":
        # duree + variables : TOUJOURS emises (defauts inclus), voir
        # credits_style() — visual_style() reste le chemin des 5 autres
        style = credits_style(p)
    else:
        style = visual_style(tpl, p)      # parametres visuels whitelistes
    if style:
        src = src.replace("</head>", style + "</head>", 1)
    fstyle = font_style(tpl, p)           # "" si police par defaut (inchange)
    if fstyle:
        src = src.replace("</head>", fstyle + "</head>", 1)
    return src


def preview_html(tpl, params=None):
    """HTML d'apercu : contenu injecte + fond #16082B + etat visible (playing)."""
    src = compose_html(tpl, params)
    inject = ("<style>html,body{background:#16082B!important}</style>\n"
              "<script>document.body.classList.add('playing');</script>\n"
              "</body>")
    return src.replace("</body>", inject, 1)


def build_render_html(tpl, params=None):
    src = compose_html(tpl, params)
    with io.open(TMP_HTML, "w", encoding="utf-8") as fh:
        fh.write(src)
    return TMP_HTML


# =============================================================================
#  Encodage + QC marges
# =============================================================================
def encode(frames_dir, out_name, total, skip_preview=False):
    """Encode les frames -> .mov (alpha) + .mp4 (preview sur noir)."""
    pattern = os.path.join(frames_dir, "frame_%04d.png")
    scale = f"scale={WIDTH}:{HEIGHT}:flags=lanczos+accurate_rnd"

    mov_out = os.path.join(EXPORTS_DIR, f"TalkShow_{out_name}.mov")
    # 1080i50 "meme instant" — validé par mesure automatique A/B (combing A=18.53
    # FILTRE 50i : SÉPARATION GÉNÉRIQUE vs SYNTHÉS FIXES
    if 'generique' in frames_dir.lower():
        # Générique (défilant) : Hack mathématique anti-scintillement
        vf_mov = (
            f"{scale},fps=25,format=rgba,"
            "geq="
            "r='p(X,2*floor(Y/2))':"
            "g='p(X,2*floor(Y/2))':"
            "b='p(X,2*floor(Y/2))':"
            "a='p(X,2*floor(Y/2))',"
            "setparams=field_mode=tff"
        )
    else:
        # Synthés fixes (Invite, etc.) : Entrelacement broadcast pur (tinterlace)
        vf_mov = f"{scale},format=rgba,tinterlace=mode=interleave_top"
    cmd_mov = [
        "ffmpeg", "-y", "-framerate", str(FPS),
        "-i", pattern,
        "-vf", vf_mov,
        "-field_order", "tt",
        "-c:v", "qtrle",
        "-pix_fmt", "rgba",
        mov_out,
    ]
    run_ffmpeg_progress(cmd_mov, total, ".MOV (Alpha)")

    mp4_out = None
    if not skip_preview:
        mp4_out = os.path.join(PREVIEW_DIR, f"TalkShow_{out_name}.mp4")
        cmd_mp4 = [
            "ffmpeg", "-y",
            "-f", "lavfi",
            "-i", f"color=c=0x111111:s={WIDTH}x{HEIGHT}:r={FPS}",
            "-framerate", str(FPS),
            "-i", pattern,
            "-filter_complex", f"[1:v]{scale},format=rgba[fg];[0:v][fg]overlay=format=auto:shortest=1",
            "-c:v", "libx264", "-preset", "medium", "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            mp4_out,
        ]
        run_ffmpeg_progress(cmd_mp4, total, ".MP4 (Aperçu)")
    return mov_out, mp4_out


def qc_frame(frames_dir, index=100):
    """Marges mesurees (bbox alpha / SSAA) — mesure, sans jugement de spec.

    index=100 -> t = 2,00 s, phase de maintien : le bloc est en place.
    """
    try:
        import numpy as np
        from PIL import Image
    except Exception:
        return None
    path = os.path.join(frames_dir, "frame_%04d.png" % index)
    if not os.path.exists(path):
        return None
    a = np.asarray(Image.open(path).convert("RGBA"))
    al = a[..., 3]
    ys, xs = np.where(al > 8)
    if not len(xs):
        return {"empty": True}
    s = float(SSAA)
    h, w = al.shape
    return {"r": round((w - 1 - int(xs.max())) / s), "b": round((h - 1 - int(ys.max())) / s),
            "t": round(int(ys.min()) / s), "l": round(int(xs.min()) / s)}


# =============================================================================
#  Rendu
# =============================================================================
def render_one(page, html_path, out_name, total, skip_preview, on_frame=None):
    """Capture les `total` images du fichier puis encode. Retourne (mov, mp4)."""
    frames_dir = os.path.join(BASE_DIR, "frames_%s" % out_name.lower())
    if os.path.exists(frames_dir):
        shutil.rmtree(frames_dir)
    os.makedirs(frames_dir)

    url = "file:///" + html_path.replace(os.sep, "/")
    page.goto(url, wait_until="load")

    # polices : celles du document (dont la police personnalisee eventuelle)
    # doivent etre CHARGEES avant la 1re capture -> jamais de .mov en repli
    page.evaluate(FONT_PRELOAD)
    missing = page.evaluate(FONT_WAIT)
    if missing:
        raise RuntimeError("police(s) non chargee(s) avant capture : %s"
                           % ", ".join(missing))
    page.wait_for_timeout(300)

    # declenche l'animation validee SANS timer JS : la duree du clip couvre
    # toute la timeline (V1b : coupe franche hors clip ; Invite : sortie V2
    # terminee 550 ms avant la fin du clip)
    page.evaluate("document.body.classList.add('playing')")

    # Freeze every animation on its own timeline
    page.evaluate("""
        window.animationsReady = false;
        Promise.all(document.getAnimations().map(a => a.ready)).then(list => {
            window.animations = list;
            window.animations.forEach(a => { try { a.pause(); a.currentTime = 0; } catch (e) {} });
            window.setFrameTime = function (ms) {
                window.animations.forEach(a => { try { a.currentTime = ms; } catch (e) {} });
            };
            window.animationsReady = true;
        });
    """)
    page.wait_for_function("window.animationsReady === true")

    for i in range(total):
        page.evaluate(f"window.setFrameTime({int(i * (1000 / FPS))})")
        page.screenshot(path=os.path.join(frames_dir, "frame_%04d.png" % i),
                        omit_background=True)
        if on_frame:
            on_frame(i, total)
        elif i % 50 == 0:
            print(f"  frame {i}/{total}")

    print("  encodage...")
    mov, mp4 = encode(frames_dir, out_name, total, skip_preview=skip_preview)
    return mov, mp4, frames_dir


def run_render(tpl, params=None, frames=None, skip_preview=False, on_frame=None):
    """Rend un template. Retourne (mov, mp4, total, qc). Supprime les fichiers temporaires."""
    info = TEMPLATES.get(tpl) or TEMPLATES["invite"]
    total = template_frames(tpl, params, frames)
    html_path = build_render_html(tpl, params)
    frames_dir = None
    import datetime
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    unique_out = f"{info['out']}_{timestamp}"
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True, args=[
                "--force-color-profile=srgb"
            ])
            page = browser.new_page(viewport={"width": WIDTH, "height": HEIGHT},
                                    device_scale_factor=SSAA)
            try:
                mov, mp4, frames_dir = render_one(page, html_path, unique_out,
                                                  total, skip_preview,
                                                  on_frame=on_frame)
            finally:
                browser.close()
        qc = qc_frame(frames_dir, min(100, total - 1))
        return mov, mp4, total, qc
    finally:
        if os.path.exists(html_path):
            try:
                os.remove(html_path)
            except OSError:
                pass
        if frames_dir:
            shutil.rmtree(frames_dir, ignore_errors=True)



def run_preview_render(tpl, params, frames_max=150):
    if tpl == 'generique':
        frames_max = 250  # 5 secondes pour bien voir le défilement
    total = min(frames_max, template_frames(tpl, params, None))
    # Pour le générique, on limite également à frames_max pour ne pas bloquer le système
    html_path = build_render_html(tpl, params)
    
    import datetime
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    frames_dir = os.path.join(BASE_DIR, f"frames_preview_{timestamp}")
    if os.path.exists(frames_dir):
        shutil.rmtree(frames_dir)
    os.makedirs(frames_dir)
    
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True, args=["--force-color-profile=srgb"])
            page = browser.new_page(viewport={"width": WIDTH, "height": HEIGHT}, device_scale_factor=SSAA)
            url = "file:///" + html_path.replace(os.sep, "/")
            page.goto(url, wait_until="load")
            
            # 1. Vérification exacte des polices comme render_one
            page.evaluate(FONT_PRELOAD)
            missing = page.evaluate(FONT_WAIT)
            if missing:
                raise RuntimeError(f"Police(s) non chargée(s) pour le preview : {', '.join(missing)}")
            page.wait_for_timeout(300)
            
            page.evaluate("document.body.classList.add('playing')")
            
            # 2. Même logique de timeline exacte que render_one
            page.evaluate("""
                window.animationsReady = false;
                Promise.all(document.getAnimations().map(a => a.ready)).then(list => {
                    window.animations = list;
                    window.animations.forEach(a => { try { a.pause(); a.currentTime = 0; } catch (e) {} });
                    window.setFrameTime = function (ms) {
                        window.animations.forEach(a => { try { a.currentTime = ms; } catch (e) {} });
                    };
                    window.animationsReady = true;
                });
            """)
            
            try:
                page.wait_for_function("window.animationsReady === true", timeout=2000)
            except Exception:
                pass
            
            for i in range(total):
                t_ms = int(i * (1000 / FPS))
                page.evaluate(f"if(window.setFrameTime) window.setFrameTime({t_ms});")
                page.screenshot(path=os.path.join(frames_dir, f"frame_{i:04d}.png"), omit_background=True)
            browser.close()
            
        pattern = os.path.join(frames_dir, "frame_%04d.png")
        
        # 3. Stratégie de framerate : preview progressif 50fps
        # Le MP4 sert uniquement au navigateur PC. On n'entrelace pas (pas de tinterlace ni geq field_mode).
        # On garde le scale Lanczos strict.
        scale = f"scale={WIDTH}:{HEIGHT}:flags=lanczos+accurate_rnd"
        vf_mov = f"{scale},format=rgba"
        
        out_name = f"web_preview_{timestamp}.mp4"
        out_mp4 = os.path.join(EXPORTS_DIR, out_name)
        
        # Fond gris pour voir le wash et l'alpha. Durée dynamique basée sur total frames.
        duration_sec = total / FPS
        bg_filter = f"color=c=gray:s={WIDTH}x{HEIGHT}:r={FPS}:d={duration_sec}"
        
        cmd = [
            "ffmpeg", "-y",
            "-f", "lavfi", "-i", bg_filter,
            "-framerate", str(FPS), "-i", pattern,
            "-filter_complex", f"[1:v]{vf_mov}[fg];[0:v][fg]overlay=format=auto:shortest=1",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "12", "-pix_fmt", "yuv444p",
            out_mp4
        ]
        run(cmd)
        return out_name
    finally:
        if os.path.exists(html_path):
            try: os.remove(html_path)
            except: pass
        if os.path.exists(frames_dir):
            shutil.rmtree(frames_dir, ignore_errors=True)

def _run(tpl, params, frames):
    """Rendu DIRECT (bouton « GENERER LE .MOV ») — memes transitions d'etat
    que la file. Le verrou RUN est pris par l'appelant (do_POST)."""
    try:
        def cb(i, total):
            JOB["progress"] = i + 1
            JOB["total"] = total
            # Quand toutes les frames sont capturées, signale la phase FFmpeg
            if i + 1 >= total:
                JOB["state"] = "encoding"

        JOB["total"] = template_frames(tpl, params, frames)
        mov, _mp4, total, qc = run_render(tpl, params, frames,
                                          skip_preview=True, on_frame=cb)
        JOB.update(state="done", progress=total,
                   file=os.path.basename(mov), qc=qc)
        print("[ok] %s | marges: %s" % (os.path.basename(mov), qc))
    except Exception as exc:
        JOB.update(state="error", error="%s: %s" % (type(exc).__name__, exc))
        print("[erreur] %s" % JOB["error"])
    finally:
        RUN.release()


# =============================================================================
#  FILE D'ATTENTE DES RENDUS — sequentielle, un seul rendu lourd a la fois
# =============================================================================
# * chaque job porte un SNAPSHOT profond (copy.deepcopy) des parametres au
#   moment de l'ajout : les modifications ulterieures du panneau n'y touchent
#   plus (template, contenu, couleurs, polices, tailles...).
# * un seul worker + le MEME verrou RUN que le bouton « GENERER LE .MOV »
#   direct -> impossible d'avoir deux Playwright/FFmpeg simultanes.
# * erreur d'un job = etat ❌ conserve puis PASSE AU SUIVANT automatiquement.
# * persistance legere : PANNEAU_DE_CONTROLE/queue.json (etat au demarrage :
#   les jobs ⏳ sont repris, un job 🔄 coupe en cours devient ❌ interrompu —
#   aucun demarrage automatique, l'utilisateur relance avec « GENERER TOUT »).
RUN = threading.Lock()                 # un seul rendu a la fois (direct OU file)
JOB = {"state": "idle", "progress": 0, "total": 0,
       "file": None, "error": None, "tpl": None, "qc": None}
QUEUE = []
QLOCK = threading.RLock()              # reentrant : _queue_save() partout
QWORKER = {"alive": False}             # un seul worker a la fois
QSEQ = {"id": 0}
QUEUE_FILE = os.path.join(BASE_DIR, "PANNEAU_DE_CONTROLE", "queue.json")
QSTATES = ("pending", "running", "done", "error")   # ⏳ 🔄 ✅ ❌


def _queue_save():
    """Snapshot disque (params inclus) — jamais bloquant."""
    try:
        with QLOCK:
            data = {"jobs": [dict(j) for j in QUEUE]}
        os.makedirs(os.path.dirname(QUEUE_FILE), exist_ok=True)
        with io.open(QUEUE_FILE, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=1)
    except Exception:
        pass                       # la persistance ne doit jamais casser la file


def _queue_load():
    """Etat au demarrage du serveur. pending repris (demarrage explicite),
    running -> error « interrompu » (pas de reprise automatique d'un rendu)."""
    try:
        with io.open(QUEUE_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return
    jobs = data.get("jobs") if isinstance(data, dict) else None
    if not isinstance(jobs, list):
        return
    with QLOCK:
        del QUEUE[:]
        for j in jobs:
            if not isinstance(j, dict) or j.get("tpl") not in TEMPLATES:
                continue
            if j.get("state") == "running":
                j["state"] = "error"
                j["error"] = "interrompu (redémarrage du serveur)"
            if j.get("state") not in QSTATES:
                j["state"] = "pending"
            QUEUE.append(j)
        QSEQ["id"] = max([int(j.get("id") or 0) for j in QUEUE] or [0]) + 1


def queue_snapshot():
    """Etat pour l'UI : sans les params (inutiles a l'affichage)."""
    with QLOCK:
        jobs = [{k: v for k, v in j.items() if k != "params"} for j in QUEUE]
    return {"jobs": jobs, "total": len(jobs),
            "done": sum(1 for j in jobs if j["state"] == "done"),
            "errors": sum(1 for j in jobs if j["state"] == "error"),
            "pending": sum(1 for j in jobs if j["state"] == "pending"),
            "running": QWORKER["alive"]}


def queue_add(tpl, params, frames=None):
    """Ajoute un rendu (snapshot des params) et lance le worker si besoin."""
    tpl = tpl if tpl in TEMPLATES else "invite"
    with QLOCK:
        QSEQ["id"] += 1
        job = {"id": QSEQ["id"], "tpl": tpl, "label": TEMPLATES[tpl]["label"],
               "params": copy.deepcopy(params if isinstance(params, dict) else {}),
               "frames": frames, "state": "pending", "progress": 0,
               "total": template_frames(tpl, params, frames),
               "error": None, "file": None, "qc": None}
        QUEUE.append(job)
        position = sum(1 for j in QUEUE if j["state"] == "pending")
        job_id = job["id"]
    _queue_save()
    _queue_start()              # execution automatique, sequentielle
    return {"id": job_id, "position": position}


def queue_remove(job_id):
    """Retire UN job en attente (un rendu en cours n'est pas retirable)."""
    removed = False
    with QLOCK:
        for i, j in enumerate(QUEUE):
            if j["id"] == job_id and j["state"] == "pending":
                QUEUE.pop(i)
                removed = True
                break
    if removed:
        _queue_save()
    return removed


def queue_clear():
    """Vide la file : tout sauf un rendu eventuellement en cours."""
    with QLOCK:
        before = len(QUEUE)
        QUEUE[:] = [j for j in QUEUE if j["state"] == "running"]
        removed = before - len(QUEUE)
    _queue_save()
    return removed


def _queue_start():
    """Demarre le worker UNIQUEMENT s'il n'en tourne pas deja (idempotent)."""
    with QLOCK:
        if QWORKER["alive"] or not any(j["state"] == "pending" for j in QUEUE):
            return False
        QWORKER["alive"] = True
    threading.Thread(target=_queue_worker, daemon=True).start()
    return True


def _queue_worker():
    """Boucle unique : 1 job apres l'autre, meme verrou RUN que le direct."""
    while True:
        with QLOCK:
            job = next((j for j in QUEUE if j["state"] == "pending"), None)
            if job is None:
                QWORKER["alive"] = False
                return
        RUN.acquire()           # attend un rendu direct en cours -> jamais 2
        with QLOCK:
            # re-verifie : le job a pu etre retire/vider pendant l'attente
            if job["state"] != "pending" or not any(j is job for j in QUEUE):
                RUN.release()
                continue
            job.update(state="running", progress=0)
            job_id, tpl, params, frames = job["id"], job["tpl"], job["params"], job["frames"]
        JOB.update(state="rendering", progress=0, total=job["total"],
                   file=None, error=None, tpl=tpl, qc=None)
        print("[file] job #%d (%s)..." % (job_id, tpl))
        try:
            def cb(i, total, _id=job_id):
                with QLOCK:
                    for j in QUEUE:
                        if j["id"] == _id:
                            j["progress"] = i + 1
                JOB["progress"] = i + 1
                JOB["total"] = total
                # Quand frames terminées → signale encodage FFmpeg
                if i + 1 >= total:
                    JOB["state"] = "encoding"

            mov, _mp4, total, qc = run_render(tpl, params, frames,
                                              skip_preview=True, on_frame=cb)
            name = os.path.basename(mov)
            with QLOCK:
                for j in QUEUE:
                    if j["id"] == job_id:
                        j.update(state="done", progress=total, file=name, qc=qc)
            JOB.update(state="done", progress=total, file=name, qc=qc)
            print("[file ok] #%d %s | marges: %s" % (job_id, name, qc))
        except Exception as exc:
            err = "%s: %s" % (type(exc).__name__, exc)
            with QLOCK:
                for j in QUEUE:
                    if j["id"] == job_id:
                        j.update(state="error", error=err)
            JOB.update(state="error", error=err)
            print("[file erreur] #%d %s — passage au suivant" % (job_id, err))
        finally:
            RUN.release()
            _queue_save()       # etat suivant : le worker reprend au tour d'apres


# =============================================================================
#  Serveur local : / (interface)  /preview  /render  /status  /reveal  /file
# =============================================================================
def serve(open_browser=True):
    import webbrowser
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import urlparse, parse_qs, unquote

    os.makedirs(EXPORTS_DIR, exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)

    # RUN / JOB / _run + file d'attente : module-level (partages direct/file)
    _queue_load()                 # jobs en attente repris (demarrage explicite)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _json(self, code, obj):
            data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _bytes(self, code, data, ctype, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            for key, val in (extra or {}).items():
                self.send_header(key, val)
            self.end_headers()
            self.wfile.write(data)

        def _safe_tpl(self, value):
            tpl = (value or "").strip().lower()
            return tpl if tpl in TEMPLATES else "invite"

        # ---- GET -------------------------------------------------------
        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)

            if u.path in ("/", "/index.html"):
                if not os.path.exists(UI_PAGE):
                    self._json(404, {"error": "TALKSHOW.html absent"})
                    return
                with io.open(UI_PAGE, "rb") as fh:
                    self._bytes(200, fh.read(), "text/html; charset=utf-8")

            elif u.path.startswith("/assets/"):
                root = os.path.realpath(BASE_DIR)
                full = os.path.realpath(os.path.join(root, unquote(u.path[1:])))
                allowed = os.path.join(root, "assets")
                if not (full.startswith(allowed + os.sep) or full == allowed) \
                        or not os.path.isfile(full):
                    self._json(404, {"error": "fichier absent"})
                    return
                ext = full.rsplit(".", 1)[-1].lower()
                ctype = {"css": "text/css; charset=utf-8",
                         "js": "application/javascript; charset=utf-8",
                         "woff": "font/woff",
                         "woff2": "font/woff2",
                         "otf": "font/otf",
                         "ttf": "font/ttf"}.get(ext, "application/octet-stream")
                with open(full, "rb") as fh:
                    self._bytes(200, fh.read(), ctype)

            elif u.path == "/preview":
                tpl = self._safe_tpl((q.get("tpl") or [""])[0])
                params = None
                raw = (q.get("p") or [""])[0]
                if raw:
                    try:
                        params = json.loads(raw)
                    except Exception:
                        params = None
                try:
                    data = preview_html(tpl, params).encode("utf-8")
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
                    return
                self._bytes(200, data, "text/html; charset=utf-8")

            elif u.path == "/params":
                tpls = {}
                for key, info in TEMPLATES.items():
                    defs = visual_defs(key)
                    tpls[key] = {
                        "label": info["label"],
                        "colors": [d for d in defs if d["type"] == "color"],
                        "numbers": [d for d in defs if d["type"] == "number"],
                        "selects": [d for d in defs if d["type"] == "select"],
                        "defaults": visual_defaults(key),
                    }
                self._json(200, {
                    "groups": GROUP_LABELS,
                    "fonts": [{"id": f["id"], "label": f["label"],
                               "files": [x["file"] for x in f["files"]]}
                              for f in sorted(FONT_FAMILIES.values(),
                                              key=lambda x: x["label"].lower())],
                    "palettes": {"pop": {"label": "POP TV — palette actuelle par défaut",
                                         "colors": {cid: COLOR_TOKENS[cid][2]
                                                    for cid in COLOR_TOKENS}}},
                    "tpls": tpls,
                })

            elif u.path == "/status":
                self._json(200, dict(JOB))

            elif u.path == "/queue":
                self._json(200, queue_snapshot())

            elif u.path == "/reveal":
                try:
                    os.startfile(EXPORTS_DIR)       # ouvre le dossier dans l'Explorateur
                except Exception:
                    pass
                self._json(200, {"ok": True})

            elif u.path == "/file":
                name = os.path.basename((q.get("name") or [""])[0])
                path = os.path.join(EXPORTS_DIR, name)
                if not name or not os.path.exists(path):
                    self._json(404, {"error": "fichier absent"})
                    return
                with open(path, "rb") as fh:
                    data = fh.read()
                self._bytes(200, data, "application/octet-stream",
                            {"Content-Disposition": 'attachment; filename="%s"' % name})

            else:
                self._json(404, {"error": "route inconnue"})

        # ---- POST ------------------------------------------------------
        def do_POST(self):
            u = urlparse(self.path)
            size = int(self.headers.get("Content-Length") or 0)
            try:
                payload = json.loads(self.rfile.read(size).decode("utf-8") or "{}")
            except Exception:
                payload = {}

            if u.path == "/render":
                # rendu direct (bouton existant) : identique, verrou non bloquant
                tpl = self._safe_tpl(payload.get("tpl"))
                params = payload.get("params") or None
                frames = payload.get("frames")

                if not RUN.acquire(blocking=False):
                    self._json(409, {"ok": False, "error": "un rendu est deja en cours"})
                    return
                JOB.update(state="rendering", progress=0,
                           total=template_frames(tpl, params, frames),
                           file=None, error=None, tpl=tpl, qc=None)
                print("[rendu demande] tpl=%s" % tpl)
                threading.Thread(target=_run, args=(tpl, params, frames), daemon=True).start()
                self._json(200, {"ok": True, "tpl": tpl})
                return

            if u.path == "/preview-render":
                tpl = self._safe_tpl(payload.get("tpl"))
                params = payload.get("params") or None
                try:
                    # Bloquant (prend environ 15 secondes pour 150 frames)
                    mp4_name = run_preview_render(tpl, params, frames_max=150)
                    self._json(200, {"ok": True, "url": "/file?name=" + mp4_name})
                except Exception as exc:
                    self._json(500, {"ok": False, "error": str(exc)})
                return

            if u.path == "/queue/add":
                info = queue_add(self._safe_tpl(payload.get("tpl")),
                                 payload.get("params") or None,
                                 payload.get("frames"))
                self._json(200, dict(info, ok=True))
                return
            if u.path == "/queue/remove":
                ok = queue_remove(payload.get("id"))
                self._json(200 if ok else 404, {"ok": ok})
                return
            if u.path == "/queue/clear":
                self._json(200, {"ok": True, "removed": queue_clear()})
                return
            if u.path == "/queue/start":
                started = _queue_start()
                self._json(200, dict(queue_snapshot(), ok=True, started=started))
                return

            self._json(404, {"error": "route inconnue"})

    try:
        httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError:
        # serveur deja lance (2e double-clic) : on ouvre juste la page
        print("Serveur deja actif -> ouverture de la page.")
        if open_browser:
            webbrowser.open(URL)
        return

    print("Pret : %s" % URL)
    if open_browser:
        webbrowser.open(URL)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


# =============================================================================
#  CLI : rendu direct
# =============================================================================
def cli_render(keys, frames=None, skip_preview=False):
    os.makedirs(EXPORTS_DIR, exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    # banniere = la duree REELLE du plus long clip demandé (Invite : 500 img
    # / 10,00 s ; V1b : 250 / 5,00 s ; genérique : dynamique ~378)
    n = frames or max(template_frames(k) for k in keys)
    print("Render engine — %s frames @ %d fps (%.1f s) — SSAA x%d"
          % (n, FPS, n / FPS, SSAA))
    for key in keys:
        info = TEMPLATES[key]
        print("\n--- %s (%s) ---" % (info["label"], info["file"]))
        # Correctif couleurs CLI : visual_defaults injecte les valeurs CSS par
        # defaut (bg, name, role_c, badge_bg, border1, border2, glow...) via
        # visual_style() -> compose_html(). Sans cela, params=None -> aucune
        # variable injectee -> synthe sans couleur.
        default_params = dict(DEFAULTS.get(key, {}))
        default_params.update(visual_defaults(key))
        mov, mp4, total, qc = run_render(key, default_params, frames, skip_preview)
        msg = "  OK -> %s" % os.path.basename(mov)
        if mp4:
            msg += "  +  %s" % os.path.basename(mp4)
        print(msg + "  | marges: %s" % qc)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", action="store_true", help="Interface web (le .bat)")
    parser.add_argument("--no-open", action="store_true",
                        help="Avec --serve : ne pas ouvrir le navigateur")
    parser.add_argument("--only", default=None,
                        help="Rendre un seul template (Invite/Nom/Titre/Bug/Fullscreen/Generique)")
    parser.add_argument("--frames", type=int, default=None, help="Limiter les images (test)")
    parser.add_argument("--no-preview", action="store_true", help="Ne pas produire le .mp4")
    args = parser.parse_args()

    if args.serve:
        serve(open_browser=not args.no_open)
        return

    keys = list(TEMPLATES)
    if args.only:
        wanted = args.only.strip().lower()
        keys = [k for k in TEMPLATES if k.lower() == wanted]
        if not keys:
            raise SystemExit("Template introuvable: %s (%s)"
                             % (args.only, ", ".join(TEMPLATES)))
    cli_render(keys, frames=args.frames, skip_preview=args.no_preview)

    try:
        print("\nتمّ الرندر.")
    except UnicodeEncodeError:
        print("\n[OK] Rendu termine.")


if __name__ == "__main__":
    main()
