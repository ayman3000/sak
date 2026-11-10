// libedit (ships with macOS) for line editing: arrow keys, history, Ctrl-R.
//
// sak uses libedit's own API (histedit.h), not its readline layer: the
// readline layer can't show the line while it's being edited, and its key
// hook drops everything outside ASCII. The calls below are the variadic ones
// (el_set, history), which Swift can't call; everything else is called from
// Swift directly.
#include <stdio.h>
#include <wchar.h>
#include <histedit.h>

typedef char *(*sak_prompt_fn)(EditLine *);
typedef int (*sak_getc_fn)(EditLine *, wchar_t *);
typedef unsigned char (*sak_key_fn)(EditLine *, int);

/// History, loaded from `file` when it exists.
static inline History *sak_history_new(const char *file) {
    History *h = history_init();
    HistEvent ev;
    history(h, &ev, H_SETSIZE, 2000);
    history(h, &ev, H_LOAD, file);
    return h;
}

/// Adds a line and saves the file.
static inline void sak_history_add(History *h, const char *line, const char *file) {
    HistEvent ev;
    history(h, &ev, H_ENTER, line);
    history(h, &ev, H_SAVE, file);
}

/// An emacs-mode editor with history, the keys the readline layer bound
/// (Ctrl-R, Home/End/Delete, word movement), a key reader and a Tab function.
static inline EditLine *sak_editor_new(History *h, sak_prompt_fn prompt, sak_getc_fn getc, sak_key_fn tab) {
    EditLine *e = el_init("sak", stdin, stdout, stderr);
    el_set(e, EL_PROMPT, prompt);
    el_set(e, EL_EDITOR, "emacs");
    el_set(e, EL_SIGNAL, 1);
    el_set(e, EL_HIST, history, h);
    el_wset(e, EL_GETCFN, getc);
    el_set(e, EL_ADDFN, "sak-complete", "Complete a slash command", tab);
    el_set(e, EL_BIND, "^I", "sak-complete", NULL);
    el_set(e, EL_BIND, "^R", "em-inc-search-prev", NULL);
    el_set(e, EL_BIND, "\\e[1~", "ed-move-to-beg", NULL);
    el_set(e, EL_BIND, "\\e[4~", "ed-move-to-end", NULL);
    el_set(e, EL_BIND, "\\e[7~", "ed-move-to-beg", NULL);
    el_set(e, EL_BIND, "\\e[8~", "ed-move-to-end", NULL);
    el_set(e, EL_BIND, "\\e[H", "ed-move-to-beg", NULL);
    el_set(e, EL_BIND, "\\e[F", "ed-move-to-end", NULL);
    el_set(e, EL_BIND, "\\e[3~", "ed-delete-next-char", NULL);
    el_set(e, EL_BIND, "\\e[1;5C", "em-next-word", NULL);
    el_set(e, EL_BIND, "\\e[1;5D", "ed-prev-word", NULL);
    el_set(e, EL_BIND, "\\e[5C", "em-next-word", NULL);
    el_set(e, EL_BIND, "\\e[5D", "ed-prev-word", NULL);
    el_set(e, EL_BIND, "\\e\\e[C", "em-next-word", NULL);
    el_set(e, EL_BIND, "\\e\\e[D", "ed-prev-word", NULL);
    el_source(e, NULL);   // ~/.editrc, as before
    return e;
}

/// Puts the terminal back in editing mode and redraws the prompt and line.
static inline void sak_editor_restore(EditLine *e) {
    el_set(e, EL_PREP_TERM, 1);
    el_set(e, EL_REFRESH);
}

static inline int sak_cc_refresh(void) { return CC_REFRESH; }
static inline int sak_cc_norm(void) { return CC_NORM; }
