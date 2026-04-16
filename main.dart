import 'dart:collection';
import 'dart:io';

enum RequestType { read, write }

enum ControllerState { idle, compareTag, allocate, writeBack }

class CPURequest {
  RequestType type;
  int address;
  int data;

  CPURequest(this.type, this.address, {this.data = 0});
}

class CacheLine {
  bool valid = false;
  bool dirty = false;
  int tag = 0;
  int data = 0;
}

class MainMemory {
  int latencyCounter = 0;
  bool readySignal = false;
  final int memLatency = 4;

  List<int> dataStore = List.generate(256, (index) => index * 10);

  void request() {
    readySignal = false;
    latencyCounter = memLatency;
  }

  void update() {
    if (latencyCounter > 0) {
      latencyCounter--;
      if (latencyCounter == 0) {
        readySignal = true;
      }
    }
  }

  int readData(int address) => dataStore[address];
  void writeData(int address, int data) => dataStore[address] = data;
}

class CacheController {
  ControllerState currentState = ControllerState.idle;
  bool cpuReadySignal = true;

  late List<CacheLine> cacheStore;
  final int numLines;

  late CPURequest currentReq;
  int currentIndex = 0;
  int currentTag = 0;
  bool waitingForMem = false;

  CacheController(this.numLines) {
    cacheStore = List.generate(numLines, (_) => CacheLine());
  }

  void extractAddress(int addr) {
    currentIndex = addr % numLines;
    currentTag = addr ~/ numLines;
  }

  int reconstructAddress(int tag, int index) {
    return (tag * numLines) + index;
  }

  void update(MainMemory memory, bool hasReq, CPURequest req) {
    switch (currentState) {
      case ControllerState.idle:
        cpuReadySignal = true;
        if (hasReq) {
          currentReq = req;
          extractAddress(currentReq.address);
          currentState = ControllerState.compareTag;
          cpuReadySignal = false;
        }
        break;

      case ControllerState.compareTag:
        cpuReadySignal = false;
        if (cacheStore[currentIndex].valid &&
            cacheStore[currentIndex].tag == currentTag) {
          // HIT
          if (currentReq.type == RequestType.write) {
            cacheStore[currentIndex].data = currentReq.data;
            cacheStore[currentIndex].dirty = true;
          } else {
            // ignoring this  read request
          }
          currentState = ControllerState.idle;
          cpuReadySignal = true;
        } else {
          // MISS
          if (cacheStore[currentIndex].valid &&
              cacheStore[currentIndex].dirty) {
            currentState = ControllerState.writeBack;
          } else {
            currentState = ControllerState.allocate;
          }
        }
        break;

      case ControllerState.writeBack:
        cpuReadySignal = false;
        if (!waitingForMem) {
          memory.request();
          waitingForMem = true;
        } else if (memory.readySignal) {
          // update memory with my dirty data
          int evictedAddr = reconstructAddress(
            cacheStore[currentIndex].tag,
            currentIndex,
          );
          memory.writeData(evictedAddr, cacheStore[currentIndex].data);

          waitingForMem = false;
          currentState = ControllerState.allocate;
        }
        break;

      case ControllerState.allocate:
        cpuReadySignal = false;
        if (!waitingForMem) {
          memory.request();
          waitingForMem = true;
        } else if (memory.readySignal) {
          // put fetched data to cache
          int fetchedData = memory.readData(currentReq.address);

          cacheStore[currentIndex].valid = true;
          cacheStore[currentIndex].dirty = false;
          cacheStore[currentIndex].tag = currentTag;
          cacheStore[currentIndex].data = fetchedData;

          waitingForMem = false;
          currentState = ControllerState.compareTag; // switch back to access
        }
        break;
    }
  }

  String getStateName() {
    return currentState.toString().split('.').last.toUpperCase();
  }
}

void main() {
  var memory = MainMemory();
  var cache = CacheController(4);

  var cpuRequests = Queue<CPURequest>();

  // cpuRequests.add(CPURequest(RequestType.read, 10));
  // cpuRequests.add(CPURequest(RequestType.write, 10, data: 999));
  // cpuRequests.add(CPURequest(RequestType.read, 14));

  File("input.txt").readAsStringSync().trim().split("\n").forEach((line) {
    if (line.isEmpty) return;
    var parts = line.split(" ");
    var rtype = parts[0].toLowerCase() == "r" ? RequestType.read : RequestType.write;
    if (rtype == RequestType.read) {
      cpuRequests.add(CPURequest(rtype, int.parse(parts[1])));
    } else {
      cpuRequests.add(CPURequest(rtype, int.parse(parts[1]), data: int.parse(parts[2])));
    }
  });

  int clockCycle = 1;

  print(
    "${'Cycle'.padRight(8)}${'FSM State'.padRight(15)}${'Mem Busy?'.padRight(12)}Action/Request",
  );
  print("-" * 65);

  while (cpuRequests.isNotEmpty || cache.currentState != ControllerState.idle) {
    bool hasReq = cpuRequests.isNotEmpty;
    CPURequest currentReq = hasReq
        ? cpuRequests.first
        : CPURequest(RequestType.read, 0);

    // check cpu ready before running update
    bool wasReady = cache.cpuReadySignal;

    // run update on each element
    memory.update();
    cache.update(memory, hasReq, currentReq);

    // ensure dequeue if there was a signal edge
    String actionLog = "";
    if (hasReq && wasReady && !cache.cpuReadySignal) {
      String typeStr = currentReq.type == RequestType.read ? "READ" : "WRITE";
      actionLog = "Accepted $typeStr Addr: ${currentReq.address}";
      cpuRequests.removeFirst(); // deq
    }

    // print stuff
    String isMemBusy = memory.latencyCounter > 0 ? "TRUE" : "FALSE";
    print(
      "${clockCycle.toString().padRight(8)}${cache.getStateName().padRight(15)}${isMemBusy.padRight(12)}$actionLog",
    );

    clockCycle++;
    if (clockCycle > 50) break; // emergency shut down
  }

  print("-" * 65);
  print("Simulation Complete. Checking Memory Array...");
  print(
    "Memory[10]: ${memory.readData(10)} (Should be 999 from the write-back)",
  );
  print(
    "Memory[14]: ${memory.readData(14)} (Should be 140, its default initialization)",
  );
}
