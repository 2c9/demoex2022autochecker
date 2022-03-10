import json
from os import listdir
from os.path import isfile, join

mypath='/mnt/d/Results'
files = [f for f in listdir(mypath) if isfile(join(mypath, f))]
for file in files:
    with open(mypath+'/'+file, 'r') as rez:
        results = json.load(rez)
        student = file.replace('.json','')
        total = 0
        for aspect in results:
            score = aspect["Mark"]
            total += score
        print("{} - {}".format(student, total))