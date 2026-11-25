#include "EmbeddedCPython.h"

#include <Python.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static pthread_mutex_t initializationLock = PTHREAD_MUTEX_INITIALIZER;

static PyStatus appendModulePath(PyConfig *config, const char *path) {
    wchar_t *widePath = Py_DecodeLocale(path, NULL);
    if (widePath == NULL) {
        return PyStatus_Error("Could not decode a Python module search path");
    }
    PyStatus status = PyWideStringList_Append(&config->module_search_paths, widePath);
    PyMem_RawFree(widePath);
    return status;
}

int FreeTubePythonInitialize(const char *home, const char *modulePath,
                             char *error, size_t errorCapacity) {
    pthread_mutex_lock(&initializationLock);
    if (Py_IsInitialized()) {
        pthread_mutex_unlock(&initializationLock);
        return 0;
    }

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.use_system_logger = 1;
    config.module_search_paths_set = 1;

    char *standardLibrary = NULL;
    char *nativeModules = NULL;
    if (!PyStatus_Exception(status)) {
        status = PyConfig_SetBytesString(&config, &config.home, home);
    }
    if (!PyStatus_Exception(status)) {
        if (asprintf(&standardLibrary, "%s/lib/python3.15", home) == -1 ||
            asprintf(&nativeModules, "%s/lib-dynload", standardLibrary) == -1) {
            status = PyStatus_NoMemory();
        } else {
            status = appendModulePath(&config, standardLibrary);
            if (!PyStatus_Exception(status)) {
                status = appendModulePath(&config, nativeModules);
            }
            if (!PyStatus_Exception(status)) {
                status = appendModulePath(&config, modulePath);
            }
        }
    }
    if (!PyStatus_Exception(status)) {
        status = Py_InitializeFromConfig(&config);
    }

    int failed = PyStatus_Exception(status);
    if (failed) {
        snprintf(error, errorCapacity, "%s", status.err_msg ?: "Unknown Python configuration error");
    }
    PyConfig_Clear(&config);
    free(nativeModules);
    free(standardLibrary);
    if (!failed) {
        // Release the initial thread state so later work can acquire the GIL on its worker.
        PyEval_SaveThread();
    }

    pthread_mutex_unlock(&initializationLock);
    return failed;
}

int FreeTubePythonAcquireGIL(void) {
    return (int)PyGILState_Ensure();
}

void FreeTubePythonReleaseGIL(int state) {
    PyGILState_Release((PyGILState_STATE)state);
}
