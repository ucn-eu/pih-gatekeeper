import numpy
import operator
import json
import os
import sys

from pylab import *

base=os.getcwd()
archive = sys.argv[1]
folder=os.path.join(base, archive)
print("read logs from directory ", folder)

data_files = [f for f in os.listdir(folder)]

cases = {}

# aggregate logs from different files

for f in data_files:
    path = os.path.join(folder, f)
    #print "process %s" % path

    fd = open(path)
    obj = json.load(fd)
    fd.close()

    for case in obj.keys():
        base_time = int(obj[case]['start'])

        for k in obj[case].keys():
            time = int(obj[case][k])
            obj[case][k] = time - base_time


        acc = cases[case] if case in cases else []
        acc.append(obj[case])
        cases[case] = acc

#print cases

# sort
'''
for k in cases.keys():
    array = cases[k]

    for inx in range(len(array)):
        entry = array[inx]
        array[inx] = sorted(entry.items(), key=operator.itemgetter(1))

print cases
'''

# calculate the stats

meta = [('0', ['start', 'cert', 'unauthorized']),
        ('1', ['start', 'cert', 'check', 'insert']),
        ('2', ['start', 'cert', 'check', 'conf'])]

stats = {}

for meta_entry in meta:
    c = meta_entry[0]
    keys = meta_entry[1]

    arr = cases[c]
    result = {}

    for key in keys:
        tmp = []

        for entry in arr:
            #print entry
            tmp.append(entry[key])

        tmp = numpy.array(tmp)
        result[key] = (numpy.mean(tmp), numpy.std(tmp))

    stats[c] = result

print(stats)
