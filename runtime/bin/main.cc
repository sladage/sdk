// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "include/dart_api.h"
#include "include/dart_tools_api.h"

#include "bin/builtin.h"
#include "bin/dartutils.h"
#include "bin/directory.h"
#include "bin/embedded_dart_io.h"
#include "bin/eventhandler.h"
#include "bin/extensions.h"
#include "bin/file.h"
#include "bin/isolate_data.h"
#include "bin/log.h"
#include "bin/platform.h"
#include "bin/process.h"
#include "bin/thread.h"
#include "bin/utils.h"
#include "bin/vmservice_impl.h"
#include "platform/globals.h"
#include "platform/hashmap.h"
#include "platform/text_buffer.h"
#include "zlib/zlib.h"

namespace dart {
namespace bin {

// vm_isolate_snapshot_buffer points to a snapshot for the vm isolate if we
// link in a snapshot otherwise it is initialized to NULL.
extern const uint8_t* vm_isolate_snapshot_buffer;

// isolate_snapshot_buffer points to a snapshot for an isolate if we link in a
// snapshot otherwise it is initialized to NULL.
extern const uint8_t* isolate_snapshot_buffer;

/**
 * Global state used to control and store generation of application snapshots
 * (script/full).
 * A full application snapshot can be generated and run using the following
 * commands
 * - Generating a full application snapshot :
 * dart_bootstrap --full-snapshot-after-run=<filename> --package-root=<dirs>
 *   <script_uri> [<script_options>]
 * - Running the full application snapshot generated above :
 * dart --run-full-snapshot=<filename> <script_uri> [<script_options>]
 */
static bool generate_script_snapshot = false;
static bool generate_full_snapshot_after_run = false;
static bool run_full_snapshot = false;
static const char* snapshot_filename = NULL;

// Value of the --package-root flag.
// (This pointer points into an argv buffer and does not need to be
// free'd.)
static const char* commandline_package_root = NULL;

// Value of the --packages flag.
// (This pointer points into an argv buffer and does not need to be
// free'd.)
static const char* commandline_packages_file = NULL;


// Global flag that is used to indicate that we want to compile all the
// dart functions and not run anything.
static bool compile_all = false;


// Global flag that is used to indicate that we want to compile all the
// dart functions before running main and not compile anything thereafter.
static bool gen_precompiled_snapshot = false;


// Global flag that is used to indicate that we want to run from a precompiled
// snapshot.
static bool run_precompiled_snapshot = false;


// Value of the --gen/run_precompiled_snapshot flag.
// (This pointer points into an argv buffer and does not need to be
// free'd.)
static const char* precompiled_snapshot_directory = NULL;


// Global flag that is used to indicate that we want to compile everything in
// the same way as precompilation before main, then continue running in the
// same process.
// Always set this with dart_noopt.
#if defined(DART_PRECOMPILER) && !defined(DART_NO_SNAPSHOT)
static const bool is_noopt = true;
#else
static const bool is_noopt = false;
#endif


extern const char* kPrecompiledLibraryName;
extern const char* kPrecompiledInstructionsSymbolName;
extern const char* kPrecompiledDataSymbolName;
static const char* kPrecompiledVmIsolateName = "precompiled.vmisolate";
static const char* kPrecompiledIsolateName = "precompiled.isolate";
static const char* kPrecompiledInstructionsName = "precompiled.S";
static const char* kVMIsolateSuffix = "vmisolate";
static const char* kIsolateSuffix = "isolate";

// Global flag that is used to indicate that we want to trace resolution of
// URIs and the loading of libraries, parts and scripts.
static bool trace_loading = false;


static const char* DEFAULT_VM_SERVICE_SERVER_IP = "127.0.0.1";
static const int DEFAULT_VM_SERVICE_SERVER_PORT = 8181;
// VM Service options.
static const char* vm_service_server_ip = DEFAULT_VM_SERVICE_SERVER_IP;
// The 0 port is a magic value which results in the first available port
// being allocated.
static int vm_service_server_port = -1;


// Exit code indicating an API error.
static const int kApiErrorExitCode = 253;
// Exit code indicating a compilation error.
static const int kCompilationErrorExitCode = 254;
// Exit code indicating an unhandled error that is not a compilation error.
static const int kErrorExitCode = 255;
// Exit code indicating a vm restart request.  Never returned to the user.
static const int kRestartRequestExitCode = 1000;

// Global flag that is used to indicate that the VM should do a clean
// shutdown.
static bool do_vm_shutdown = true;

static void ErrorExit(int exit_code, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  Log::VPrintErr(format, arguments);
  va_end(arguments);
  fflush(stderr);

  Dart_ExitScope();
  Dart_ShutdownIsolate();

  // Terminate process exit-code handler.
  Process::TerminateExitCodeHandler();

  char* error = Dart_Cleanup();
  if (error != NULL) {
    Log::PrintErr("VM cleanup failed: %s\n", error);
    free(error);
  }

  if (do_vm_shutdown) {
    EventHandler::Stop();
  }
  Platform::Exit(exit_code);
}


// The environment provided through the command line using -D options.
static dart::HashMap* environment = NULL;

static bool IsValidFlag(const char* name,
                        const char* prefix,
                        intptr_t prefix_length) {
  intptr_t name_length = strlen(name);
  return ((name_length > prefix_length) &&
          (strncmp(name, prefix, prefix_length) == 0));
}


static bool version_option = false;
static bool ProcessVersionOption(const char* arg,
                                 CommandLineOptions* vm_options) {
  if (*arg != '\0') {
    return false;
  }
  version_option = true;
  return true;
}


static bool help_option = false;
static bool ProcessHelpOption(const char* arg, CommandLineOptions* vm_options) {
  if (*arg != '\0') {
    return false;
  }
  help_option = true;
  return true;
}


static bool verbose_option = false;
static bool ProcessVerboseOption(const char* arg,
                                 CommandLineOptions* vm_options) {
  if (*arg != '\0') {
    return false;
  }
  verbose_option = true;
  return true;
}


static bool ProcessPackageRootOption(const char* arg,
                                     CommandLineOptions* vm_options) {
  ASSERT(arg != NULL);
  if (*arg == '\0' || *arg == '-') {
    return false;
  }
  commandline_package_root = arg;
  return true;
}


static bool ProcessPackagesOption(const char* arg,
                                     CommandLineOptions* vm_options) {
  ASSERT(arg != NULL);
  if (*arg == '\0' || *arg == '-') {
    return false;
  }
  commandline_packages_file = arg;
  return true;
}


static void* GetHashmapKeyFromString(char* key) {
  return reinterpret_cast<void*>(key);
}


static bool ExtractPortAndIP(const char *option_value,
                             int *out_port,
                             const char **out_ip,
                             int default_port,
                             const char *default_ip) {
  // [option_value] has to be one of the following formats:
  //   - ""
  //   - ":8181"
  //   - "=8181"
  //   - ":8181/192.168.0.1"
  //   - "=8181/192.168.0.1"

  if (*option_value== '\0') {
    *out_ip = default_ip;
    *out_port = default_port;
    return true;
  }

  if ((*option_value != '=') && (*option_value != ':')) {
    return false;
  }

  int port = atoi(option_value + 1);
  const char *slash = strstr(option_value, "/");
  if (slash == NULL) {
    *out_ip = default_ip;
    *out_port = port;
    return true;
  }

  int _, n;
  if (sscanf(option_value + 1, "%d/%d.%d.%d.%d%n",  // NOLINT(runtime/printf)
             &_, &_, &_, &_, &_, &n)) {
    if (option_value[1 + n] == '\0') {
      *out_ip = slash + 1;
      *out_port = port;
      return true;
    }
  }
  return false;
}


static bool ProcessEnvironmentOption(const char* arg,
                                     CommandLineOptions* vm_options) {
  ASSERT(arg != NULL);
  if (*arg == '\0') {
    // Ignore empty -D option.
    Log::PrintErr("No arguments given to -D option\n");
    return true;
  }
  if (environment == NULL) {
    environment = new HashMap(&HashMap::SameStringValue, 4);
  }
  // Split the name=value part of the -Dname=value argument.
  char* name;
  char* value = NULL;
  const char* equals_pos = strchr(arg, '=');
  if (equals_pos == NULL) {
    // No equal sign (name without value) currently not supported.
    Log::PrintErr("No value given to -D option\n");
    return false;
  } else {
    int name_len = equals_pos - arg;
    if (name_len == 0) {
      Log::PrintErr("No name given to -D option\n");
      return false;
    }
    // Split name=value into name and value.
    name = reinterpret_cast<char*>(malloc(name_len + 1));
    strncpy(name, arg, name_len);
    name[name_len] = '\0';
    value = strdup(equals_pos + 1);
  }
  HashMap::Entry* entry = environment->Lookup(
      GetHashmapKeyFromString(name), HashMap::StringHash(name), true);
  ASSERT(entry != NULL);  // Lookup adds an entry if key not found.
  entry->value = value;
  return true;
}


static bool ProcessCompileAllOption(const char* arg,
                                    CommandLineOptions* vm_options) {
  ASSERT(arg != NULL);
  if (*arg != '\0') {
    return false;
  }
  compile_all = true;
  return true;
}


static bool ProcessGenPrecompiledSnapshotOption(
    const char* arg,
    CommandLineOptions* vm_options) {
#if !defined(DART_PRECOMPILER)
  Log::PrintErr("Precompiled snapshots must be generated with "
                "dart_bootstrap.\n");
  return false;
#else  // defined(DART_PRECOMPILER)
  ASSERT(arg != NULL);
  if ((arg[0] == '=') || (arg[0] == ':')) {
    precompiled_snapshot_directory = &arg[1];
  } else {
    precompiled_snapshot_directory = arg;
  }
  gen_precompiled_snapshot = true;
  vm_options->AddArgument("--precompilation");
  return true;
#endif  // defined(DART_PRECOMPILER)
}


static bool ProcessRunPrecompiledSnapshotOption(
    const char* arg,
    CommandLineOptions* vm_options) {
  ASSERT(arg != NULL);
  precompiled_snapshot_directory = arg;
  if ((precompiled_snapshot_directory[0] == '=') ||
      (precompiled_snapshot_directory[0] == ':')) {
    precompiled_snapshot_directory = &precompiled_snapshot_directory[1];
  }
  run_precompiled_snapshot = true;
  vm_options->AddArgument("--precompilation");
  return true;
}


static bool ProcessSnapshotOptionHelper(const char* filename,
                                        bool* snapshot_option) {
  ASSERT((filename != NULL) && (strlen(filename) != 0));
  snapshot_filename = filename;
  *snapshot_option = true;
  if (generate_script_snapshot && generate_full_snapshot_after_run) {
    Log::PrintErr("--snapshot and --snapshot-after-run options"
                  " cannot be specified at the same time\n");
    *snapshot_option = false;
    return false;
  }
  return true;
}


static bool ProcessScriptSnapshotOption(const char* filename,
                                        CommandLineOptions* vm_options) {
  if ((filename == NULL) || (strlen(filename) == 0)) {
    return false;
  }
  // Ensure that we are already running using a full snapshot.
  if (isolate_snapshot_buffer == NULL) {
    Log::PrintErr("Script snapshots cannot be generated in this version of"
                  " Dart\n");
    return false;
  }
  return ProcessSnapshotOptionHelper(filename, &generate_script_snapshot);
}


static bool ProcessFullSnapshotAfterRunOption(
    const char* filename, CommandLineOptions* vm_options) {
  if ((filename == NULL) || (strlen(filename) == 0)) {
    return false;
  }
  // Ensure that we are running 'dart_bootstrap'.
  if (isolate_snapshot_buffer != NULL) {
    Log::PrintErr("Full Application snapshots must be generated with"
                  " dart_bootstrap\n");
    return false;
  }
  return ProcessSnapshotOptionHelper(filename,
                                     &generate_full_snapshot_after_run);
}


static bool ProcessRunFullSnapshotOption(
    const char* filename, CommandLineOptions* vm_options) {
#ifndef DART_PRODUCT_BINARY
  Log::PrintErr("Full Application snapshots can only be be run with"
                " dart_product\n");
  return false;
#else
  return ProcessSnapshotOptionHelper(filename, &run_full_snapshot);
#endif  // defined(DART_PRODUCT_BINARY)
}


static bool ProcessEnableVmServiceOption(const char* option_value,
                                         CommandLineOptions* vm_options) {
  ASSERT(option_value != NULL);

  if (!ExtractPortAndIP(option_value,
                        &vm_service_server_port,
                        &vm_service_server_ip,
                        DEFAULT_VM_SERVICE_SERVER_PORT,
                        DEFAULT_VM_SERVICE_SERVER_IP)) {
    Log::PrintErr("unrecognized --enable-vm-service option syntax. "
                  "Use --enable-vm-service[:<port number>[/<IPv4 address>]]\n");
    return false;
  }

  return true;
}


static bool ProcessObserveOption(const char* option_value,
                                 CommandLineOptions* vm_options) {
  ASSERT(option_value != NULL);

  if (!ExtractPortAndIP(option_value,
                        &vm_service_server_port,
                        &vm_service_server_ip,
                        DEFAULT_VM_SERVICE_SERVER_PORT,
                        DEFAULT_VM_SERVICE_SERVER_IP)) {
    Log::PrintErr("unrecognized --observe option syntax. "
                  "Use --observe[:<port number>[/<IPv4 address>]]\n");
    return false;
  }

  vm_options->AddArgument("--pause-isolates-on-exit");
  vm_options->AddArgument("--pause-isolates-on-unhandled-exceptions");
  vm_options->AddArgument("--warn-on-pause-with-no-debugger");
  return true;
}


static bool ProcessTraceLoadingOption(const char* arg,
                                      CommandLineOptions* vm_options) {
  if (*arg != '\0') {
    return false;
  }
  trace_loading = true;
  return true;
}



static bool ProcessShutdownOption(const char* arg,
                                  CommandLineOptions* vm_options) {
  ASSERT(arg != NULL);
  if (*arg == '\0') {
    do_vm_shutdown = true;
    vm_options->AddArgument("--shutdown");
    return true;
  }

  if ((*arg != '=') && (*arg != ':')) {
    return false;
  }

  if (strcmp(arg + 1, "true") == 0) {
    do_vm_shutdown = true;
    vm_options->AddArgument("--shutdown");
    return true;
  } else if (strcmp(arg + 1, "false") == 0) {
    do_vm_shutdown = false;
    vm_options->AddArgument("--no-shutdown");
    return true;
  }

  return false;
}


static struct {
  const char* option_name;
  bool (*process)(const char* option, CommandLineOptions* vm_options);
} main_options[] = {
  // Standard options shared with dart2js.
  { "-D", ProcessEnvironmentOption },
  { "-h", ProcessHelpOption },
  { "--help", ProcessHelpOption },
  { "--packages=", ProcessPackagesOption },
  { "--package-root=", ProcessPackageRootOption },
  { "-v", ProcessVerboseOption },
  { "--verbose", ProcessVerboseOption },
  { "--version", ProcessVersionOption },

  // VM specific options to the standalone dart program.
  { "--compile_all", ProcessCompileAllOption },
  { "--enable-vm-service", ProcessEnableVmServiceOption },
  { "--gen-precompiled-snapshot", ProcessGenPrecompiledSnapshotOption },
  { "--observe", ProcessObserveOption },
  { "--run-precompiled-snapshot", ProcessRunPrecompiledSnapshotOption },
  { "--shutdown", ProcessShutdownOption },
  { "--snapshot=", ProcessScriptSnapshotOption },
  { "--full-snapshot-after-run=", ProcessFullSnapshotAfterRunOption },
  { "--run-full-snapshot=", ProcessRunFullSnapshotOption },
  { "--trace-loading", ProcessTraceLoadingOption },
  { NULL, NULL }
};


static bool ProcessMainOptions(const char* option,
                               CommandLineOptions* vm_options) {
  int i = 0;
  const char* name = main_options[0].option_name;
  int option_length = strlen(option);
  while (name != NULL) {
    int length = strlen(name);
    if ((option_length >= length) && (strncmp(option, name, length) == 0)) {
      if (main_options[i].process(option + length, vm_options)) {
        return true;
      }
    }
    i += 1;
    name = main_options[i].option_name;
  }
  return false;
}


// Parse out the command line arguments. Returns -1 if the arguments
// are incorrect, 0 otherwise.
static int ParseArguments(int argc,
                          char** argv,
                          CommandLineOptions* vm_options,
                          char** script_name,
                          CommandLineOptions* dart_options,
                          bool* print_flags_seen,
                          bool* verbose_debug_seen) {
  const char* kPrefix = "--";
  const intptr_t kPrefixLen = strlen(kPrefix);

  // Store the executable name.
  Platform::SetExecutableName(argv[0]);

  // Start the rest after the executable name.
  int i = 1;

  // Parse out the vm options.
  while (i < argc) {
    if (ProcessMainOptions(argv[i], vm_options)) {
      i++;
    } else {
      // Check if this flag is a potentially valid VM flag.
      const char* kChecked = "-c";
      const char* kPackageRoot = "-p";
      if (strncmp(argv[i], kPackageRoot, strlen(kPackageRoot)) == 0) {
        if (!ProcessPackageRootOption(argv[i] + strlen(kPackageRoot),
                                      vm_options)) {
          i++;
          if ((argv[i] == NULL) ||
               !ProcessPackageRootOption(argv[i], vm_options)) {
            Log::PrintErr("Invalid option specification : '%s'\n", argv[i - 1]);
            i++;
            break;
          }
        }
        i++;
        continue;  // '-p' is not a VM flag so don't add to vm options.
      } else if (strncmp(argv[i], kChecked, strlen(kChecked)) == 0) {
        vm_options->AddArgument("--checked");
        i++;
        continue;  // '-c' is not a VM flag so don't add to vm options.
      } else if (!IsValidFlag(argv[i], kPrefix, kPrefixLen)) {
        break;
      }
      // The following two flags are processed by both the embedder and
      // the VM.
      const char* kPrintFlags1 = "--print-flags";
      const char* kPrintFlags2 = "--print_flags";
      const char* kVerboseDebug1 = "--verbose_debug";
      const char* kVerboseDebug2 = "--verbose-debug";
      if ((strncmp(argv[i], kPrintFlags1, strlen(kPrintFlags1)) == 0) ||
          (strncmp(argv[i], kPrintFlags2, strlen(kPrintFlags2)) == 0)) {
        *print_flags_seen = true;
      } else if ((strncmp(argv[i],
                          kVerboseDebug1,
                          strlen(kVerboseDebug1)) == 0) ||
                 (strncmp(argv[i],
                          kVerboseDebug2,
                          strlen(kVerboseDebug2)) == 0)) {
        *verbose_debug_seen = true;
      }
      vm_options->AddArgument(argv[i]);
      i++;
    }
  }

  // The arguments to the VM are at positions 1 through i-1 in argv.
  Platform::SetExecutableArguments(i, argv);

  // Get the script name.
  if (i < argc) {
    *script_name = argv[i];
    i++;
  } else {
    return -1;
  }

  // Parse out options to be passed to dart main.
  while (i < argc) {
    dart_options->AddArgument(argv[i]);
    i++;
  }

  // Verify consistency of arguments.
  if ((commandline_package_root != NULL) &&
      (commandline_packages_file != NULL)) {
    Log::PrintErr("Specifying both a packages directory and a packages "
                  "file is invalid.\n");
    return -1;
  }
  if (is_noopt) {
    if (gen_precompiled_snapshot) {
      Log::PrintErr("Running dart_noopt with --gen_precompiled_snapshot"
                    " is invalid.\n");
      return -1;
    }
    if (run_precompiled_snapshot) {
      Log::PrintErr("Running dart_noopt with --run_precompiled_snapshot"
                    " is invalid.\n");
      return -1;
    }
  }
  if (run_full_snapshot && run_precompiled_snapshot) {
    Log::PrintErr("Specifying --run_full_snapshot and"
                  " --run_precompiled_snapshot is invalid.\n");
    return -1;
  }
  if ((generate_full_snapshot_after_run || gen_precompiled_snapshot) &&
      (run_full_snapshot || run_precompiled_snapshot)) {
    Log::PrintErr("Specifying an option to generate a snapshot and"
                  " run using a snapshot is invalid.\n");
    return -1;
  }

  return 0;
}


static Dart_Handle CreateRuntimeOptions(CommandLineOptions* options) {
  int options_count = options->count();
  Dart_Handle dart_arguments = Dart_NewList(options_count);
  if (Dart_IsError(dart_arguments)) {
    return dart_arguments;
  }
  for (int i = 0; i < options_count; i++) {
    Dart_Handle argument_value =
        DartUtils::NewString(options->GetArgument(i));
    if (Dart_IsError(argument_value)) {
      return argument_value;
    }
    Dart_Handle result = Dart_ListSetAt(dart_arguments, i, argument_value);
    if (Dart_IsError(result)) {
      return result;
    }
  }
  return dart_arguments;
}


static Dart_Handle EnvironmentCallback(Dart_Handle name) {
  uint8_t* utf8_array;
  intptr_t utf8_len;
  Dart_Handle result = Dart_Null();
  Dart_Handle handle = Dart_StringToUTF8(name, &utf8_array, &utf8_len);
  if (Dart_IsError(handle)) {
    handle = Dart_ThrowException(
        DartUtils::NewDartArgumentError(Dart_GetError(handle)));
  } else {
    char* name_chars = reinterpret_cast<char*>(malloc(utf8_len + 1));
    memmove(name_chars, utf8_array, utf8_len);
    name_chars[utf8_len] = '\0';
    const char* value = NULL;
    if (environment != NULL) {
      HashMap::Entry* entry = environment->Lookup(
          GetHashmapKeyFromString(name_chars),
          HashMap::StringHash(name_chars),
          false);
      if (entry != NULL) {
        value = reinterpret_cast<char*>(entry->value);
      }
    }
    if (value != NULL) {
      result = Dart_NewStringFromUTF8(reinterpret_cast<const uint8_t*>(value),
                                      strlen(value));
    }
    free(name_chars);
  }
  return result;
}


#define CHECK_RESULT(result)                                                   \
  if (Dart_IsError(result)) {                                                  \
    *error = strdup(Dart_GetError(result));                                    \
    if (Dart_IsCompilationError(result)) {                                     \
      *exit_code = kCompilationErrorExitCode;                                  \
    } else if (Dart_IsApiError(result)) {                                      \
      *exit_code = kApiErrorExitCode;                                          \
    } else if (Dart_IsVMRestartRequest(result)) {                              \
      *exit_code = kRestartRequestExitCode;                                    \
    } else {                                                                   \
      *exit_code = kErrorExitCode;                                             \
    }                                                                          \
    Dart_ExitScope();                                                          \
    Dart_ShutdownIsolate();                                                    \
    return NULL;                                                               \
  }                                                                            \


// Returns true on success, false on failure.
static Dart_Isolate CreateIsolateAndSetupHelper(const char* script_uri,
                                                const char* main,
                                                const char* package_root,
                                                const char* packages_config,
                                                Dart_IsolateFlags* flags,
                                                char** error,
                                                int* exit_code) {
  ASSERT(script_uri != NULL);
#if defined(DART_PRODUCT_BINARY)
  if (strcmp(script_uri, DART_VM_SERVICE_ISOLATE_NAME) == 0) {
    // No service isolate support.
    return NULL;
  }
#endif  // defined(DART_PRODUCT_BINARY)

  if (run_full_snapshot &&
      (strcmp(script_uri, DART_VM_SERVICE_ISOLATE_NAME) == 0)) {
    // We do not create a service isolate when running a full application
    // snapshot.
    return NULL;
  }
  IsolateData* isolate_data = new IsolateData(script_uri,
                                              package_root,
                                              packages_config);
  Dart_Isolate isolate = NULL;

  isolate = Dart_CreateIsolate(script_uri,
                               main,
                               isolate_snapshot_buffer,
                               flags,
                               isolate_data,
                               error);

  if (isolate == NULL) {
    delete isolate_data;
    return NULL;
  }

  Dart_EnterScope();

  if (isolate_snapshot_buffer != NULL) {
    // Setup the native resolver as the snapshot does not carry it.
    Builtin::SetNativeResolver(Builtin::kBuiltinLibrary);
    Builtin::SetNativeResolver(Builtin::kIOLibrary);
  }

  // Set up the library tag handler for this isolate.
  Dart_Handle result = Dart_SetLibraryTagHandler(DartUtils::LibraryTagHandler);
  CHECK_RESULT(result);

#if defined(DART_PRODUCT_BINARY)
  ASSERT(!Dart_IsServiceIsolate(isolate));
#else
  if (Dart_IsServiceIsolate(isolate)) {
    // If this is the service isolate, load embedder specific bits and return.
    if (!VmService::Setup(vm_service_server_ip,
                          vm_service_server_port,
                          run_precompiled_snapshot)) {
      *error = strdup(VmService::GetErrorMessage());
      return NULL;
    }
    if (compile_all) {
      result = Dart_CompileAll();
      CHECK_RESULT(result);
    }
    Dart_ExitScope();
    Dart_ExitIsolate();
    return isolate;
  }
#endif  // defined(DART_PRODUCT_BINARY)

  // Prepare builtin and other core libraries for use to resolve URIs.
  // Set up various closures, e.g: printing, timers etc.
  // Set up 'package root' for URI resolution.
  result = DartUtils::PrepareForScriptLoading(false, trace_loading);
  CHECK_RESULT(result);

  if (!run_full_snapshot) {
    // Set up the load port provided by the service isolate so that we can
    // load scripts.
    result = DartUtils::SetupServiceLoadPort();
    CHECK_RESULT(result);
  }

  // Setup package root if specified.
  result = DartUtils::SetupPackageRoot(package_root, packages_config);
  CHECK_RESULT(result);

  result = Dart_SetEnvironmentCallback(EnvironmentCallback);
  CHECK_RESULT(result);

  if (!run_precompiled_snapshot && !run_full_snapshot) {
    // Load the specified application script into the newly created isolate.
    result = DartUtils::LoadScript(script_uri);
    CHECK_RESULT(result);

    // Run event-loop and wait for script loading to complete.
    result = Dart_RunLoop();
    CHECK_RESULT(result);

    if (isolate_data->load_async_id >= 0) {
      Dart_TimelineAsyncEnd("LoadScript", isolate_data->load_async_id);
    }

    result = DartUtils::SetupIOLibrary(script_uri);
    CHECK_RESULT(result);
  } else if (run_full_snapshot) {
    result = DartUtils::SetupIOLibrary(script_uri);
    CHECK_RESULT(result);
  }

  // Make the isolate runnable so that it is ready to handle messages.
  Dart_ExitScope();
  Dart_ExitIsolate();
  bool retval = Dart_IsolateMakeRunnable(isolate);
  if (!retval) {
    *error = strdup("Invalid isolate state - Unable to make it runnable");
    Dart_EnterIsolate(isolate);
    Dart_ShutdownIsolate();
    return NULL;
  }

  return isolate;
}

#undef CHECK_RESULT


static Dart_Isolate CreateIsolateAndSetup(const char* script_uri,
                                          const char* main,
                                          const char* package_root,
                                          const char* package_config,
                                          Dart_IsolateFlags* flags,
                                          void* data, char** error) {
  // The VM should never call the isolate helper with a NULL flags.
  ASSERT(flags != NULL);
  ASSERT(flags->version == DART_FLAGS_CURRENT_VERSION);
  if ((package_root != NULL) && (package_config != NULL)) {
    *error = strdup("Invalid arguments - Cannot simultaneously specify "
                    "package root and package map.");
    return NULL;
  }

  int exit_code = 0;
  return CreateIsolateAndSetupHelper(script_uri,
                                     main,
                                     package_root,
                                     package_config,
                                     flags,
                                     error,
                                     &exit_code);
}


static void PrintVersion() {
  Log::PrintErr("Dart VM version: %s\n", Dart_VersionString());
}


static void PrintUsage() {
  Log::PrintErr(
      "Usage: dart [<vm-flags>] <dart-script-file> [<dart-options>]\n"
      "\n"
      "Executes the Dart script passed as <dart-script-file>.\n"
      "\n");
  if (!verbose_option) {
    Log::PrintErr(
"Common options:\n"
"--checked or -c\n"
"  Insert runtime type checks and enable assertions (checked mode).\n"
"--help or -h\n"
"  Display this message (add -v or --verbose for information about\n"
"  all VM options).\n"
"--package-root=<path> or -p<path>\n"
"  Where to find packages, that is, \"package:...\" imports.\n"
"--packages=<path>\n"
"  Where to find a package spec file.\n"
"--observe[=<port>[/<bind-address>]]\n"
"  The observe flag is used to run a program with a default set of options\n"
"  for debugging under Observatory. With the default options, Observatory\n"
"  will be available at http://127.0.0.1:8181/ (default port is 8181,\n"
"  default bind address is 127.0.0.1).  Isolates will pause at exit and\n"
"  when they throw unhandled exceptions.\n"
"--version\n"
"  Print the VM version.\n");
  } else {
    Log::PrintErr(
"Supported options:\n"
"--checked or -c\n"
"  Insert runtime type checks and enable assertions (checked mode).\n"
"--help or -h\n"
"  Display this message (add -v or --verbose for information about\n"
"  all VM options).\n"
"--package-root=<path> or -p<path>\n"
"  Where to find packages, that is, \"package:...\" imports.\n"
"--packages=<path>\n"
"  Where to find a package spec file.\n"
"--observe[=<port>[/<bind-address>]]\n"
"  The observe flag is used to run a program with a default set of options\n"
"  for debugging under Observatory. With the default options, Observatory\n"
"  will be available at http://127.0.0.1:8181/ (default port is 8181,\n"
"  default bind address is 127.0.0.1).  Isolates will pause at exit and\n"
"  when they throw unhandled exceptions.\n"
"--version\n"
"  Print the VM version.\n"
"\n"
"--snapshot=<file_name>\n"
"  loads Dart script and generates a snapshot in the specified file\n"
"\n"
"--trace-loading\n"
"  enables tracing of library and script loading\n"
"\n"
"--enable-vm-service[:<port>[/<bind-address>]]\n"
"  enables the VM service and listens on specified port for connections\n"
"  (default port number is 8181, default bind address is 127.0.0.1).\n"
"\n"
"The following options are only used for VM development and may\n"
"be changed in any future version:\n");
    const char* print_flags = "--print_flags";
    Dart_SetVMFlags(1, &print_flags);
  }
}


char* BuildIsolateName(const char* script_name,
                       const char* func_name) {
  // Skip past any slashes in the script name.
  const char* last_slash = strrchr(script_name, '/');
  if (last_slash != NULL) {
    script_name = last_slash + 1;
  }

  const char* kFormat = "%s/%s";
  intptr_t len = strlen(script_name) + strlen(func_name) + 2;
  char* buffer = new char[len];
  ASSERT(buffer != NULL);
  snprintf(buffer, len, kFormat, script_name, func_name);
  return buffer;
}

static void ShutdownIsolate(void* callback_data) {
  IsolateData* isolate_data = reinterpret_cast<IsolateData*>(callback_data);
  delete isolate_data;
}


static const char* ServiceRequestError(Dart_Handle error) {
  TextBuffer buffer(128);
  buffer.Printf("{\"type\":\"Error\",\"text\":\"Internal error %s\"}",
                Dart_GetError(error));
  return buffer.Steal();
}


class DartScope {
 public:
  DartScope() { Dart_EnterScope(); }
  ~DartScope() { Dart_ExitScope(); }
};


static const char* ServiceGetIOHandler(
    const char* method,
    const char** param_keys,
    const char** param_values,
    intptr_t num_params,
    void* user_data) {
  DartScope scope;
  // TODO(ajohnsen): Store the library/function in isolate data or user_data.
  Dart_Handle dart_io_str = Dart_NewStringFromCString("dart:io");
  if (Dart_IsError(dart_io_str)) {
    return ServiceRequestError(dart_io_str);
  }

  Dart_Handle io_lib = Dart_LookupLibrary(dart_io_str);
  if (Dart_IsError(io_lib)) {
    return ServiceRequestError(io_lib);
  }

  Dart_Handle handler_function_name =
      Dart_NewStringFromCString("_serviceObjectHandler");
  if (Dart_IsError(handler_function_name)) {
    return ServiceRequestError(handler_function_name);
  }

  // TODO(johnmccutchan): paths is no longer used.  Update the io
  // _serviceObjectHandler function to use json rpc.
  Dart_Handle paths = Dart_NewList(0);
  Dart_Handle keys = Dart_NewList(num_params);
  Dart_Handle values = Dart_NewList(num_params);
  for (int i = 0; i < num_params; i++) {
    Dart_ListSetAt(keys, i, Dart_NewStringFromCString(param_keys[i]));
    Dart_ListSetAt(values, i, Dart_NewStringFromCString(param_values[i]));
  }
  Dart_Handle args[] = {paths, keys, values};
  Dart_Handle result = Dart_Invoke(io_lib, handler_function_name, 3, args);
  if (Dart_IsError(result)) {
    return ServiceRequestError(result);
  }

  const char *json;
  result = Dart_StringToCString(result, &json);
  if (Dart_IsError(result)) {
    return ServiceRequestError(result);
  }
  return strdup(json);
}


static const char* kStdoutStreamId = "Stdout";
static const char* kStderrStreamId = "Stderr";


static bool ServiceStreamListenCallback(const char* stream_id) {
  if (strcmp(stream_id, kStdoutStreamId) == 0) {
    SetCaptureStdout(true);
    return true;
  } else if (strcmp(stream_id, kStderrStreamId) == 0) {
    SetCaptureStderr(true);
    return true;
  }
  return false;
}


static void ServiceStreamCancelCallback(const char* stream_id) {
  if (strcmp(stream_id, kStdoutStreamId) == 0) {
    SetCaptureStdout(false);
  } else if (strcmp(stream_id, kStderrStreamId) == 0) {
    SetCaptureStderr(false);
  }
}


static void WriteSnapshotFile(const char* snapshot_directory,
                              const char* filename,
                              bool write_magic_number,
                              const uint8_t* buffer,
                              const intptr_t size) {
  char* concat = NULL;
  const char* qualified_filename;
  if ((snapshot_directory != NULL) && strlen(snapshot_directory) > 0) {
    intptr_t len = snprintf(NULL, 0, "%s/%s", snapshot_directory, filename);
    concat = new char[len + 1];
    snprintf(concat, len + 1, "%s/%s", snapshot_directory, filename);
    qualified_filename = concat;
  } else {
    qualified_filename = filename;
  }

  File* file = File::Open(qualified_filename, File::kWriteTruncate);
  ASSERT(file != NULL);

  if (write_magic_number) {
    // Write the magic number to indicate file is a script snapshot.
    DartUtils::WriteMagicNumber(file);
  }

  if (!file->WriteFully(buffer, size)) {
    ErrorExit(kErrorExitCode,
              "Unable to open file %s for writing snapshot\n",
              qualified_filename);
  }
  delete file;
  if (concat != NULL) {
    delete concat;
  }
}


static void ReadSnapshotFile(const char* snapshot_directory,
                             const char* filename,
                             const uint8_t** buffer) {
  char* concat = NULL;
  const char* qualified_filename;
  if ((snapshot_directory != NULL) && strlen(snapshot_directory) > 0) {
    intptr_t len = snprintf(NULL, 0, "%s/%s", snapshot_directory, filename);
    concat = new char[len + 1];
    snprintf(concat, len + 1, "%s/%s", snapshot_directory, filename);
    qualified_filename = concat;
  } else {
    qualified_filename = filename;
  }

  void* file = DartUtils::OpenFile(qualified_filename, false);
  if (file == NULL) {
    fprintf(stderr,
            "Error: Unable to open file %s for reading snapshot\n",
            qualified_filename);
    fflush(stderr);
    Platform::Exit(kErrorExitCode);
  }
  intptr_t len = -1;
  DartUtils::ReadFile(buffer, &len, file);
  if (*buffer == NULL || len == -1) {
    fprintf(stderr,
            "Error: Unable to read snapshot file %s\n", qualified_filename);
    fflush(stderr);
    Platform::Exit(kErrorExitCode);
  }
  DartUtils::CloseFile(file);
  if (concat != NULL) {
    delete concat;
  }
}


static void* LoadLibrarySymbol(const char* snapshot_directory,
                               const char* libname,
                               const char* symname) {
  char* concat = NULL;
  const char* qualified_libname;
  if ((snapshot_directory != NULL) && strlen(snapshot_directory) > 0) {
    intptr_t len = snprintf(NULL, 0, "%s/%s", snapshot_directory, libname);
    concat = new char[len + 1];
    snprintf(concat, len + 1, "%s/%s", snapshot_directory, libname);
    qualified_libname = concat;
  } else {
    qualified_libname = libname;
  }
  void* library = Extensions::LoadExtensionLibrary(qualified_libname);
  if (library == NULL) {
    Log::PrintErr("Error: Failed to load library '%s'\n", qualified_libname);
    Platform::Exit(kErrorExitCode);
  }
  void* symbol = Extensions::ResolveSymbol(library, symname);
  if (symbol == NULL) {
    Log::PrintErr("Error: Failed to load symbol '%s'\n", symname);
    Platform::Exit(kErrorExitCode);
  }
  if (concat != NULL) {
    delete concat;
  }
  return symbol;
}


static void GenerateScriptSnapshot() {
  // First create a snapshot.
  uint8_t* buffer = NULL;
  intptr_t size = 0;
  Dart_Handle result = Dart_CreateScriptSnapshot(&buffer, &size);
  if (Dart_IsError(result)) {
    ErrorExit(kErrorExitCode, "%s\n", Dart_GetError(result));
  }

  WriteSnapshotFile(NULL, snapshot_filename, true, buffer, size);
}


static void ComputeSnapshotFilenames(const char* filename,
                                     char** vm_snapshot_fname,
                                     char** isolate_snapshot_fname) {
  intptr_t len = snprintf(NULL, 0, "%s.%s", filename, kVMIsolateSuffix);
  *vm_snapshot_fname = new char[len + 1];
  snprintf(*vm_snapshot_fname, len + 1, "%s.%s", filename, kVMIsolateSuffix);

  len = snprintf(NULL, 0, "%s.%s", filename, kIsolateSuffix);
  *isolate_snapshot_fname = new char[len + 1];
  snprintf(*isolate_snapshot_fname, len + 1, "%s.%s", filename, kIsolateSuffix);
}

static void GenerateFullSnapshot() {
  // Create a full snapshot of the script.
  Dart_Handle result;
  uint8_t* vm_isolate_buffer = NULL;
  intptr_t vm_isolate_size = 0;
  uint8_t* isolate_buffer = NULL;
  intptr_t isolate_size = 0;
  char* vm_snapshot_fname = NULL;
  char* isolate_snapshot_fname = NULL;

  result = Dart_CreateSnapshot(&vm_isolate_buffer,
                               &vm_isolate_size,
                               &isolate_buffer,
                               &isolate_size);
  if (Dart_IsError(result)) {
    ErrorExit(kErrorExitCode, "%s\n", Dart_GetError(result));
  }

  // Compute snapshot file names and write out the snapshot files.
  ComputeSnapshotFilenames(snapshot_filename,
                           &vm_snapshot_fname,
                           &isolate_snapshot_fname);
  WriteSnapshotFile(NULL,
                    vm_snapshot_fname,
                    false,
                    vm_isolate_buffer,
                    vm_isolate_size);
  WriteSnapshotFile(NULL,
                    isolate_snapshot_fname,
                    false,
                    isolate_buffer,
                    isolate_size);
}


#define CHECK_RESULT(result)                                                   \
  if (Dart_IsError(result)) {                                                  \
    if (Dart_IsVMRestartRequest(result)) {                                     \
      Dart_ExitScope();                                                        \
      Dart_ShutdownIsolate();                                                  \
      return true;                                                             \
    }                                                                          \
    const int exit_code = Dart_IsCompilationError(result) ?                    \
        kCompilationErrorExitCode : kErrorExitCode;                            \
    ErrorExit(exit_code, "%s\n", Dart_GetError(result));                       \
  }


bool RunMainIsolate(const char* script_name,
                    CommandLineOptions* dart_options) {
  // Call CreateIsolateAndSetup which creates an isolate and loads up
  // the specified application script.
  char* error = NULL;
  int exit_code = 0;
  char* isolate_name = BuildIsolateName(script_name, "main");
  Dart_Isolate isolate = CreateIsolateAndSetupHelper(script_name,
                                                     "main",
                                                     commandline_package_root,
                                                     commandline_packages_file,
                                                     NULL,
                                                     &error,
                                                     &exit_code);
  if (isolate == NULL) {
    delete [] isolate_name;
    if (exit_code == kRestartRequestExitCode) {
      free(error);
      return true;
    }
    Log::PrintErr("%s\n", error);
    free(error);
    error = NULL;
    Process::TerminateExitCodeHandler();
    error = Dart_Cleanup();
    if (error != NULL) {
      Log::PrintErr("VM cleanup failed: %s\n", error);
      free(error);
    }
    if (do_vm_shutdown) {
      EventHandler::Stop();
    }
    Platform::Exit((exit_code != 0) ? exit_code : kErrorExitCode);
  }
  delete [] isolate_name;

  Dart_EnterIsolate(isolate);
  ASSERT(isolate == Dart_CurrentIsolate());
  ASSERT(isolate != NULL);
  Dart_Handle result;

  Dart_EnterScope();

  if (generate_script_snapshot) {
    GenerateScriptSnapshot();
  } else {
    // Lookup the library of the root script.
    Dart_Handle root_lib = Dart_RootLibrary();
    // Import the root library into the builtin library so that we can easily
    // lookup the main entry point exported from the root library.
    IsolateData* isolate_data =
        reinterpret_cast<IsolateData*>(Dart_IsolateData(isolate));
    result = Dart_LibraryImportLibrary(
        isolate_data->builtin_lib(), root_lib, Dart_Null());
#ifndef DART_PRODUCT_BINARY
    if (is_noopt || gen_precompiled_snapshot) {
      // Load the embedder's portion of the VM service's Dart code so it will
      // be included in the precompiled snapshot.
      if (!VmService::LoadForGenPrecompiled()) {
        fprintf(stderr,
                "VM service loading failed: %s\n",
                VmService::GetErrorMessage());
        fflush(stderr);
        exit(kErrorExitCode);
      }
    }
#endif  // !DART_PRODUCT_BINARY

    if (compile_all) {
      result = Dart_CompileAll();
      CHECK_RESULT(result);
    }

    if (is_noopt || gen_precompiled_snapshot) {
      Dart_QualifiedFunctionName standalone_entry_points[] = {
        { "dart:_builtin", "::", "_getMainClosure" },
        { "dart:_builtin", "::", "_getPrintClosure" },
        { "dart:_builtin", "::", "_getUriBaseClosure" },
        { "dart:_builtin", "::", "_resolveUri" },
        { "dart:_builtin", "::", "_setWorkingDirectory" },
        { "dart:_builtin", "::", "_setPackageRoot" },
        { "dart:_builtin", "::", "_loadPackagesMap" },
        { "dart:_builtin", "::", "_loadDataAsync" },
        { "dart:io", "::", "_makeUint8ListView" },
        { "dart:io", "::", "_makeDatagram" },
        { "dart:io", "::", "_setupHooks" },
        { "dart:io", "::", "_getWatchSignalInternal" },
        { "dart:io", "CertificateException", "CertificateException." },
        { "dart:io", "Directory", "Directory." },
        { "dart:io", "File", "File." },
        { "dart:io", "FileSystemException", "FileSystemException." },
        { "dart:io", "HandshakeException", "HandshakeException." },
        { "dart:io", "Link", "Link." },
        { "dart:io", "OSError", "OSError." },
        { "dart:io", "TlsException", "TlsException." },
        { "dart:io", "X509Certificate", "X509Certificate._" },
        { "dart:io", "_ExternalBuffer", "set:data" },
        { "dart:io", "_Platform", "set:_nativeScript" },
        { "dart:io", "_ProcessStartStatus", "set:_errorCode" },
        { "dart:io", "_ProcessStartStatus", "set:_errorMessage" },
        { "dart:io", "_SecureFilterImpl", "get:ENCRYPTED_SIZE" },
        { "dart:io", "_SecureFilterImpl", "get:SIZE" },
        { "dart:vmservice_io", "::", "main" },
        { NULL, NULL, NULL }  // Must be terminated with NULL entries.
      };

      const bool reset_fields = gen_precompiled_snapshot;
      result = Dart_Precompile(standalone_entry_points, reset_fields);
      CHECK_RESULT(result);
    }

    if (gen_precompiled_snapshot) {
      uint8_t* vm_isolate_buffer = NULL;
      intptr_t vm_isolate_size = 0;
      uint8_t* isolate_buffer = NULL;
      intptr_t isolate_size = 0;
      uint8_t* instructions_buffer = NULL;
      intptr_t instructions_size = 0;
      result = Dart_CreatePrecompiledSnapshot(&vm_isolate_buffer,
                                              &vm_isolate_size,
                                              &isolate_buffer,
                                              &isolate_size,
                                              &instructions_buffer,
                                              &instructions_size);
      CHECK_RESULT(result);
      WriteSnapshotFile(precompiled_snapshot_directory,
                        kPrecompiledVmIsolateName,
                        false,
                        vm_isolate_buffer,
                        vm_isolate_size);
      WriteSnapshotFile(precompiled_snapshot_directory,
                        kPrecompiledIsolateName,
                        false,
                        isolate_buffer,
                        isolate_size);
      WriteSnapshotFile(precompiled_snapshot_directory,
                        kPrecompiledInstructionsName,
                        false,
                        instructions_buffer,
                        instructions_size);
    } else {
      if (Dart_IsNull(root_lib)) {
        ErrorExit(kErrorExitCode,
                  "Unable to find root library for '%s'\n",
                  script_name);
      }

      // The helper function _getMainClosure creates a closure for the main
      // entry point which is either explicitly or implictly exported from the
      // root library.
      Dart_Handle main_closure = Dart_Invoke(isolate_data->builtin_lib(),
          Dart_NewStringFromCString("_getMainClosure"), 0, NULL);
      CHECK_RESULT(main_closure);

      // Call _startIsolate in the isolate library to enable dispatching the
      // initial startup message.
      const intptr_t kNumIsolateArgs = 2;
      Dart_Handle isolate_args[kNumIsolateArgs];
      isolate_args[0] = main_closure;                        // entryPoint
      isolate_args[1] = CreateRuntimeOptions(dart_options);  // args

      Dart_Handle isolate_lib =
          Dart_LookupLibrary(Dart_NewStringFromCString("dart:isolate"));
      result = Dart_Invoke(isolate_lib,
                           Dart_NewStringFromCString("_startMainIsolate"),
                           kNumIsolateArgs, isolate_args);
      CHECK_RESULT(result);

      // Keep handling messages until the last active receive port is closed.
      result = Dart_RunLoop();
      // Generate a full snapshot after execution if specified.
      if (generate_full_snapshot_after_run) {
        if (!Dart_IsCompilationError(result) &&
            !Dart_IsVMRestartRequest(result)) {
          GenerateFullSnapshot();
        }
      }
      CHECK_RESULT(result);
    }
  }

  Dart_ExitScope();
  // Shutdown the isolate.
  Dart_ShutdownIsolate();

  // No restart.
  return false;
}

#undef CHECK_RESULT


// Observatory assets are only needed in the regular dart binary.
#if !defined(DART_PRECOMPILER)
extern unsigned int observatory_assets_archive_len;
extern const uint8_t* observatory_assets_archive;


// |input| is assumed to be a gzipped stream.
// This function allocates the output buffer in the C heap and the caller
// is responsible for freeing it.
void Decompress(const uint8_t* input, unsigned int input_len,
                uint8_t** output, unsigned int* output_length) {
  ASSERT(input != NULL);
  ASSERT(input_len > 0);
  ASSERT(output != NULL);
  ASSERT(output_length != NULL);

  // Initialize output.
  *output = NULL;
  *output_length = 0;

  const unsigned int kChunkSize = 256 * 1024;
  uint8_t chunk_out[kChunkSize];
  z_stream strm;
  strm.zalloc = Z_NULL;
  strm.zfree = Z_NULL;
  strm.opaque = Z_NULL;
  strm.avail_in = 0;
  strm.next_in = 0;
  int ret = inflateInit2(&strm, 32 + MAX_WBITS);
  ASSERT(ret == Z_OK);

  unsigned int input_cursor = 0;
  unsigned int output_cursor = 0;
  do {
    // Setup input.
    unsigned int size_in = input_len - input_cursor;
    if (size_in > kChunkSize) {
      size_in = kChunkSize;
    }
    strm.avail_in = size_in;
    strm.next_in = const_cast<uint8_t*>(&input[input_cursor]);

    // Inflate until we've exhausted the current input chunk.
    do {
      // Setup output.
      strm.avail_out = kChunkSize;
      strm.next_out = &chunk_out[0];
      // Inflate.
      ret = inflate(&strm, Z_SYNC_FLUSH);
      // We either hit the end of the stream or made forward progress.
      ASSERT((ret == Z_STREAM_END) || (ret == Z_OK));
      // Grow output buffer size.
      unsigned int size_out = kChunkSize - strm.avail_out;
      *output_length += size_out;
      *output = reinterpret_cast<uint8_t*>(realloc(*output, *output_length));
      // Copy output.
      memmove(&((*output)[output_cursor]), &chunk_out[0], size_out);
      output_cursor += size_out;
    } while (strm.avail_out == 0);

    // We've processed size_in bytes.
    input_cursor += size_in;

    // We're finished decompressing when zlib tells us.
  } while (ret != Z_STREAM_END);

  inflateEnd(&strm);
}


Dart_Handle GetVMServiceAssetsArchiveCallback() {
  uint8_t* decompressed = NULL;
  unsigned int decompressed_len = 0;
  Decompress(observatory_assets_archive,
             observatory_assets_archive_len,
             &decompressed,
             &decompressed_len);
  Dart_Handle tar_file = DartUtils::MakeUint8Array(decompressed,
                                                   decompressed_len);
  // Free decompressed memory as it has been copied into a Dart array.
  free(decompressed);
  return tar_file;
}
#else  // !defined(DART_PRECOMPILER)
static Dart_GetVMServiceAssetsArchive GetVMServiceAssetsArchiveCallback = NULL;
#endif  // !defined(DART_PRECOMPILER)


void main(int argc, char** argv) {
  char* script_name;
  const int EXTRA_VM_ARGUMENTS = 2;
  CommandLineOptions vm_options(argc + EXTRA_VM_ARGUMENTS);
  CommandLineOptions dart_options(argc);
  bool print_flags_seen = false;
  bool verbose_debug_seen = false;

  vm_options.AddArgument("--no_write_protect_code");
  // Perform platform specific initialization.
  if (!Platform::Initialize()) {
    Log::PrintErr("Initialization failed\n");
  }

  // On Windows, the argv strings are code page encoded and not
  // utf8. We need to convert them to utf8.
  bool argv_converted = ShellUtils::GetUtf8Argv(argc, argv);

  // Parse command line arguments.
  if (ParseArguments(argc,
                     argv,
                     &vm_options,
                     &script_name,
                     &dart_options,
                     &print_flags_seen,
                     &verbose_debug_seen) < 0) {
    if (help_option) {
      PrintUsage();
      Platform::Exit(0);
    } else if (version_option) {
      PrintVersion();
      Platform::Exit(0);
    } else if (print_flags_seen) {
      // Will set the VM flags, print them out and then we exit as no
      // script was specified on the command line.
      Dart_SetVMFlags(vm_options.count(), vm_options.arguments());
      Platform::Exit(0);
    } else {
      PrintUsage();
      Platform::Exit(kErrorExitCode);
    }
  }

  Thread::InitOnce();

  if (!DartUtils::SetOriginalWorkingDirectory()) {
    OSError err;
    fprintf(stderr, "Error determining current directory: %s\n", err.message());
    fflush(stderr);
    Platform::Exit(kErrorExitCode);
  }

#if !defined(PRODUCT)
  // Constant true in PRODUCT mode.
  if (generate_script_snapshot ||
      generate_full_snapshot_after_run ||
      run_full_snapshot) {
    vm_options.AddArgument("--load_deferred_eagerly");
  }
#endif

#if defined(DART_PRECOMPILER) && !defined(DART_NO_SNAPSHOT)
  // Always set --precompilation with dart_noopt.
  ASSERT(!gen_precompiled_snapshot && !run_precompiled_snapshot);
  vm_options.AddArgument("--precompilation");
#endif

  Dart_SetVMFlags(vm_options.count(), vm_options.arguments());

  // Start event handler.
  TimerUtils::InitOnce();
  EventHandler::Start();

  const uint8_t* instructions_snapshot = NULL;
  const uint8_t* data_snapshot = NULL;
  if (run_precompiled_snapshot) {
    instructions_snapshot = reinterpret_cast<const uint8_t*>(
        LoadLibrarySymbol(precompiled_snapshot_directory,
                          kPrecompiledLibraryName,
                          kPrecompiledInstructionsSymbolName));
    data_snapshot = reinterpret_cast<const uint8_t*>(
        LoadLibrarySymbol(precompiled_snapshot_directory,
                          kPrecompiledLibraryName,
                          kPrecompiledDataSymbolName));
    ReadSnapshotFile(precompiled_snapshot_directory,
                     kPrecompiledVmIsolateName,
                     &vm_isolate_snapshot_buffer);
    ReadSnapshotFile(precompiled_snapshot_directory,
                     kPrecompiledIsolateName,
                     &isolate_snapshot_buffer);

  } else if (run_full_snapshot) {
    char* vm_snapshot_fname;
    char* isolate_snapshot_fname;

    // Compute file names.
    ComputeSnapshotFilenames(snapshot_filename,
                             &vm_snapshot_fname,
                             &isolate_snapshot_fname);

    ReadSnapshotFile(NULL, vm_snapshot_fname, &vm_isolate_snapshot_buffer);
    ReadSnapshotFile(NULL, isolate_snapshot_fname, &isolate_snapshot_buffer);
    delete vm_snapshot_fname;
    delete isolate_snapshot_fname;
  }

  // Initialize the Dart VM.
  char* error = Dart_Initialize(
      vm_isolate_snapshot_buffer, instructions_snapshot, data_snapshot,
      CreateIsolateAndSetup, NULL, NULL, ShutdownIsolate,
      DartUtils::OpenFile,
      DartUtils::ReadFile,
      DartUtils::WriteFile,
      DartUtils::CloseFile,
      DartUtils::EntropySource,
      GetVMServiceAssetsArchiveCallback);
  if (error != NULL) {
    if (do_vm_shutdown) {
      EventHandler::Stop();
    }
    fprintf(stderr, "VM initialization failed: %s\n", error);
    fflush(stderr);
    free(error);
    Platform::Exit(kErrorExitCode);
  }

  Dart_RegisterIsolateServiceRequestCallback(
        "getIO", &ServiceGetIOHandler, NULL);
  Dart_SetServiceStreamCallbacks(&ServiceStreamListenCallback,
                                 &ServiceStreamCancelCallback);

  // Run the main isolate until we aren't told to restart.
  while (RunMainIsolate(script_name, &dart_options)) {
    Log::PrintErr("Restarting VM\n");
  }

  // Terminate process exit-code handler.
  Process::TerminateExitCodeHandler();

  error = Dart_Cleanup();
  if (error != NULL) {
    Log::PrintErr("VM cleanup failed: %s\n", error);
    free(error);
  }
  if (do_vm_shutdown) {
    EventHandler::Stop();
  }

  // Free copied argument strings if converted.
  if (argv_converted) {
    for (int i = 0; i < argc; i++) {
      free(argv[i]);
    }
  }

  // Free environment if any.
  if (environment != NULL) {
    for (HashMap::Entry* p = environment->Start();
         p != NULL;
         p = environment->Next(p)) {
      free(p->key);
      free(p->value);
    }
    delete environment;
  }

  Platform::Exit(Process::GlobalExitCode());
}

}  // namespace bin
}  // namespace dart

int main(int argc, char** argv) {
  dart::bin::main(argc, argv);
  UNREACHABLE();
}
