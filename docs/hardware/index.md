---
outline: false
---

<script setup>
import { data as boards } from './boards.data.mjs'
import { withBase } from 'vitepress'
const families = ['Raspberry Pi', 'RAKwireless', 'Other']
</script>

# Hardware

Every board below is a directory in [`boards/`](https://github.com/pulzar-net/PulzrOS/tree/main/boards). This page and each board's page are generated from its `board.conf` when the site is built.

A board marked **Image built by CI** has an image on every release. One that **needs device support** has its board file and OpenWrt device support in the repository and no image until that support builds and boots on a unit.

<template v-for="f in families" :key="f">
<h2 :id="f.toLowerCase().replace(/\s+/g, '-')">{{ f }}</h2>
<table>
  <thead><tr><th>Board</th><th>ID</th><th>LoRa radio</th><th>Features</th><th>Image</th></tr></thead>
  <tbody>
    <tr v-for="b in boards.filter((x) => x.family === f)" :key="b.id">
      <td><a :href="withBase(`/hardware/${b.id}`)">{{ b.name }}</a></td>
      <td><code>{{ b.id }}</code></td>
      <td>{{ b.radio }}</td>
      <td>{{ b.features }}</td>
      <td><Badge :type="b.built ? 'tip' : 'warning'" :text="b.built ? 'CI' : 'needs device support'" /></td>
    </tr>
  </tbody>
</table>
</template>

## A board that is not here

A board is a page of deltas over `boards/common/board.conf`, not a fork. See [Adding a board](/boards).
