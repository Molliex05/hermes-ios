// Lanceur du service « paie ». macOS ne donne l'accès au dossier iCloud qu'au programme que launchd démarre (le
// « processus responsable ») : on donne l'Accès complet au disque à ce petit binaire, pas à tout Python. Il lance
// toujours le même script (service.py, à côté de lui), sans argument venant de l'extérieur, et attend sa fin.
// Le script reste un enfant (posix_spawn, pas exec) pour que l'autorisation de ce binaire s'applique à lui.
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    char self[PATH_MAX], resolved[PATH_MAX], script[PATH_MAX];
    uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0 || realpath(self, resolved) == NULL) return 70;
    snprintf(script, sizeof(script), "%s/service.py", dirname(resolved));
    char *argv[] = {"/usr/bin/python3", "-I", script, NULL};
    pid_t child;
    if (posix_spawn(&child, argv[0], NULL, NULL, argv, environ) != 0) return 71;
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
