import numpy
import io
import json
import ujson
import random
import re
import os
from os import path

from spacy.munge.read_ner import tags_to_entities
from libc.string cimport memset


def align(cand_words, gold_words):
    cost, edit_path = _min_edit_path(cand_words, gold_words)
    alignment = []
    i_of_gold = 0
    for move in edit_path:
        if move == 'M':
            alignment.append(i_of_gold)
            i_of_gold += 1
        elif move == 'S':
            alignment.append(None)
            i_of_gold += 1
        elif move == 'D':
            alignment.append(None)
        elif move == 'I':
            i_of_gold += 1
        else:
            raise Exception(move)
    return alignment


punct_re = re.compile(r'\W')
def _min_edit_path(cand_words, gold_words):
    cdef:
        Pool mem
        int i, j, n_cand, n_gold
        int* curr_costs
        int* prev_costs

    # TODO: Fix this --- just do it properly, make the full edit matrix and
    # then walk back over it...
    # Preprocess inputs
    cand_words = [punct_re.sub('', w) for w in cand_words] 
    gold_words = [punct_re.sub('', w) for w in gold_words] 
    
    if cand_words == gold_words:
        return 0, ['M' for _ in gold_words]
    mem = Pool()
    n_cand = len(cand_words)
    n_gold = len(gold_words)
    # Levenshtein distance, except we need the history, and we may want different
    # costs.
    # Mark operations with a string, and score the history using _edit_cost.
    previous_row = []
    prev_costs = <int*>mem.alloc(n_gold + 1, sizeof(int))
    curr_costs = <int*>mem.alloc(n_gold + 1, sizeof(int))
    for i in range(n_gold + 1):
        cell = ''
        for j in range(i):
            cell += 'I'
        previous_row.append('I' * i)
        prev_costs[i] = i
    for i, cand in enumerate(cand_words):
        current_row = ['D' * (i + 1)]
        curr_costs[0] = i+1
        for j, gold in enumerate(gold_words):
            if gold.lower() == cand.lower():
                s_cost = prev_costs[j]
                i_cost = curr_costs[j] + 1
                d_cost = prev_costs[j + 1] + 1
            else:
                s_cost = prev_costs[j] + 1
                i_cost = curr_costs[j] + 1
                d_cost = prev_costs[j + 1] + (1 if cand else 0)

            if s_cost <= i_cost and s_cost <= d_cost:
                best_cost = s_cost
                best_hist = previous_row[j] + ('M' if gold == cand else 'S')
            elif i_cost <= s_cost and i_cost <= d_cost:
                best_cost = i_cost
                best_hist = current_row[j] + 'I'
            else:
                best_cost = d_cost
                best_hist = previous_row[j + 1] + 'D'
            
            current_row.append(best_hist)
            curr_costs[j+1] = best_cost
        previous_row = current_row
        for j in range(len(gold_words) + 1):
            prev_costs[j] = curr_costs[j]
            curr_costs[j] = 0

    return prev_costs[n_gold], previous_row[-1]


def read_json_file(loc):
    print loc
    if path.isdir(loc):
        for filename in os.listdir(loc):
            yield from read_json_file(path.join(loc, filename))
    else:
        with open(loc) as file_:
            docs = ujson.load(file_)
        for doc in docs:
            paragraphs = []
            for paragraph in doc['paragraphs']:
                sents = []
                for sent in paragraph['sentences']:
                    words = []
                    ids = []
                    tags = []
                    heads = []
                    labels = []
                    ner = []
                    for i, token in enumerate(sent['tokens']):
                        words.append(token['orth'])
                        ids.append(i)
                        tags.append(token['tag'])
                        heads.append(token['head'] + i)
                        labels.append(token['dep'])
                        ner.append(token.get('ner', '-'))
                    sents.append((
                        (ids, words, tags, heads, labels, ner),
                        sent.get('brackets', [])))
                if sents:
                    yield (paragraph.get('raw', None), sents)


def _iob_to_biluo(tags):
    out = []
    curr_label = None
    tags = list(tags)
    while tags:
        out.extend(_consume_os(tags))
        out.extend(_consume_ent(tags))
    return out


def _consume_os(tags):
    while tags and tags[0] == 'O':
        yield tags.pop(0)


def _consume_ent(tags):
    if not tags:
        return []
    target = tags.pop(0).replace('B', 'I')
    length = 1
    while tags and tags[0] == target:
        length += 1
        tags.pop(0)
    label = target[2:]
    if length == 1:
        return ['U-' + label]
    else:
        start = 'B-' + label
        end = 'L-' + label
        middle = ['I-%s' % label for _ in range(1, length - 1)]
        return [start] + middle + [end]


cdef class GoldParse:
    def __init__(self, tokens, annot_tuples, brackets=tuple(), make_projective=False):
        self.mem = Pool()
        self.loss = 0
        self.length = len(tokens)

        # These are filled by the tagger/parser/entity recogniser
        self.c.tags = <int*>self.mem.alloc(len(tokens), sizeof(int))
        self.c.heads = <int*>self.mem.alloc(len(tokens), sizeof(int))
        self.c.labels = <int*>self.mem.alloc(len(tokens), sizeof(int))
        self.c.ner = <Transition*>self.mem.alloc(len(tokens), sizeof(Transition))
        self.c.brackets = <int**>self.mem.alloc(len(tokens), sizeof(int*))
        for i in range(len(tokens)):
            self.c.brackets[i] = <int*>self.mem.alloc(len(tokens), sizeof(int))

        self.tags = [None] * len(tokens)
        self.heads = [None] * len(tokens)
        self.labels = [''] * len(tokens)
        self.ner = ['-'] * len(tokens)

        self.cand_to_gold = align([t.orth_ for t in tokens], annot_tuples[1])
        self.gold_to_cand = align(annot_tuples[1], [t.orth_ for t in tokens])

        self.orig_annot = zip(*annot_tuples)

        for i, gold_i in enumerate(self.cand_to_gold):
            if gold_i is None:
                # TODO: What do we do for missing values again?
                pass
            else:
                self.tags[i] = annot_tuples[2][gold_i]
                self.heads[i] = self.gold_to_cand[annot_tuples[3][gold_i]]
                self.labels[i] = annot_tuples[4][gold_i]
                self.ner[i] = annot_tuples[5][gold_i]
       
        # If we have any non-projective arcs, i.e. crossing brackets, consider
        # the heads for those words missing in the gold-standard.
        # This way, we can train from these sentences
        cdef int w1, w2, h1, h2
        if make_projective:
            heads = list(self.heads)
            for w1 in range(self.length):
                if heads[w1] is not None:
                    h1 = heads[w1]
                    for w2 in range(w1+1, self.length):
                        if heads[w2] is not None:
                            h2 = heads[w2]
                            if _arcs_cross(w1, h1, w2, h2):
                                self.heads[w1] = None
                                self.labels[w1] = ''
                                self.heads[w2] = None
                                self.labels[w2] = ''

        self.brackets = {}
        for (gold_start, gold_end, label_str) in brackets:
            start = self.gold_to_cand[gold_start]
            end = self.gold_to_cand[gold_end]
            if start is not None and end is not None:
                self.brackets.setdefault(start, {}).setdefault(end, set())
                self.brackets[end][start].add(label_str)

    def __len__(self):
        return self.length

    @property
    def is_projective(self):
        heads = list(self.heads)
        for w1 in range(self.length):
            if heads[w1] is not None:
                h1 = heads[w1]
                for w2 in range(self.length):
                    if heads[w2] is not None and _arcs_cross(w1, h1, w2, heads[w2]):
                        return False
        return True


cdef int _arcs_cross(int w1, int h1, int w2, int h2) except -1:
    if w1 > h1:
        w1, h1 = h1, w1
    if w2 > h2:
        w2, h2 = h2, w2
    if w1 > w2:
        w1, h1, w2, h2 = w2, h2, w1, h1
    return w1 < w2 < h1 < h2 or w1 < w2 == h2 < h1


def is_punct_label(label):
    return label == 'P' or label.lower() == 'punct'
